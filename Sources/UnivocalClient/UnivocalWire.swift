// SPDX-License-Identifier: MIT
// Copyright (c) 2026 NarNar Labs
// Univocal Connect reference implementation — released under the MIT licence
// (docs/univocal-protocol/LICENSE), independently of the host app's licence.

import Foundation

// MARK: - JSON value

/// A lenient, `Sendable` JSON value. Every Univocal Connect message is a JSON
/// object (`JSONObject`); unknown fields are simply carried along and ignored
/// (SPEC §3.3), so no message is ever rejected for having extra keys.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Integers, and doubles that are exact integers (`7.0`).
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            guard d.isFinite, d.rounded() == d, abs(d) < 9.0e15 else { return nil }
            return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

public typealias JSONObject = [String: JSONValue]

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func object(_ key: String) -> JSONObject? { self[key]?.objectValue }
    func array(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
    /// The message `type`, if present and a string.
    var messageType: String? { string("type") }
}

// MARK: - Encoding / decoding

/// Wire constants and the NDJSON codec shared by the SDK, the mock server and the probe.
public enum UnivocalWire {
    public static let protocolName = "univocal-connect"
    public static let protocolVersions: [Int] = [1]
    /// Servers MUST accept frames of at least this size (SPEC §3.1); also the
    /// client's assumed limit before `welcome` announces the real one.
    public static let minimumMaxFrameBytes = 1_048_576

    public enum CodingError: Error, Sendable, Equatable {
        case malformedJSON
        case notAnObject
        case unencodable
    }

    /// Encodes one message as compact JSON **without** the trailing newline.
    /// JSON string escaping guarantees the result contains no raw `\n`.
    public static func encode(_ object: JSONObject) throws -> Data {
        let any = toFoundation(.object(object))
        guard JSONSerialization.isValidJSONObject(any) else { throw CodingError.unencodable }
        do {
            return try JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw CodingError.unencodable
        }
    }

    /// Encodes one NDJSON frame: the message followed by a single `\n`.
    public static func frame(_ object: JSONObject) throws -> Data {
        var data = try encode(object)
        data.append(0x0A)
        return data
    }

    /// Decodes one frame (without its newline; a trailing `\r` is tolerated).
    public static func decode(_ line: Data) throws -> JSONObject {
        var line = line
        if line.last == 0x0D { line.removeLast() }
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: line, options: [])
        } catch {
            throw CodingError.malformedJSON
        }
        guard let dict = any as? [String: Any] else { throw CodingError.notAnObject }
        var out: JSONObject = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict { out[k] = fromFoundation(v) }
        return out
    }

    static func fromFoundation(_ any: Any) -> JSONValue {
        switch any {
        case let s as String:
            return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            if CFNumberIsFloatType(n) { return .double(n.doubleValue) }
            return .int(n.intValue)
        case let a as [Any]:
            return .array(a.map(fromFoundation))
        case let d as [String: Any]:
            var o: JSONObject = [:]
            for (k, v) in d { o[k] = fromFoundation(v) }
            return .object(o)
        default:
            return .null
        }
    }

    static func toFoundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .array(let a): return a.map(toFoundation)
        case .object(let o):
            var d: [String: Any] = [:]
            for (k, v) in o { d[k] = toFoundation(v) }
            return d
        }
    }
}

// MARK: - NDJSON framing

/// Splits a byte stream into NDJSON frames (SPEC §3.1). Tolerates `\r\n`,
/// skips empty lines, and refuses any frame larger than `maxFrameBytes`
/// (counting the terminating newline).
public struct NDJSONFramer: Sendable {
    public struct FrameTooLarge: Error, Sendable, Equatable {
        public let limit: Int
    }

    public var maxFrameBytes: Int
    private var buffer: [UInt8] = []
    /// Bytes of `buffer` already searched for a newline.
    private var scanned = 0

    public init(maxFrameBytes: Int) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// Number of buffered bytes that do not yet form a complete frame.
    public var pendingByteCount: Int { buffer.count }

    public mutating func push(_ data: Data) throws -> [Data] {
        buffer.append(contentsOf: data)
        var frames: [Data] = []
        var start = 0
        var searchFrom = scanned
        while let nl = buffer[searchFrom...].firstIndex(of: 0x0A) {
            if nl - start + 1 > maxFrameBytes { throw FrameTooLarge(limit: maxFrameBytes) }
            var end = nl
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            if end > start { frames.append(Data(buffer[start..<end])) }
            start = nl + 1
            searchFrom = start
        }
        if start > 0 { buffer.removeFirst(start) }
        scanned = buffer.count
        // A partial frame that can no longer fit (even with its newline) is fatal now.
        if buffer.count >= maxFrameBytes { throw FrameTooLarge(limit: maxFrameBytes) }
        return frames
    }
}
