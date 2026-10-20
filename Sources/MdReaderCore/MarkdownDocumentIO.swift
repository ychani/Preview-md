import Foundation

/// Encoding-aware reading and writing for markdown documents, shared by the
/// app and the Quick Look extension.
///
/// Reading detects byte-order marks (UTF-8, UTF-16 LE/BE), then tries UTF-8,
/// then falls back to `NSString.stringEncoding(for:...)`. Lossy decodes and
/// binary data (NUL bytes) are rejected rather than silently mangling the
/// user's file. The detected on-disk `Format` (encoding, BOM, dominant line
/// ending) travels with the document so a save writes the file back the way
/// it was found.
public enum MarkdownDocumentIO {

    // MARK: - Types

    public enum LineEnding: String, Equatable, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
        case cr = "\r"
    }

    /// How a document is laid out on disk.
    public struct Format: Equatable, Sendable {
        public var encoding: String.Encoding
        /// True if the file started with a byte-order mark (UTF-8 or UTF-16).
        public var hasByteOrderMark: Bool
        /// The file's dominant line ending. `Document.text` always uses "\n";
        /// saves convert back to this.
        public var lineEnding: LineEnding

        public init(encoding: String.Encoding, hasByteOrderMark: Bool = false, lineEnding: LineEnding = .lf) {
            self.encoding = encoding
            self.hasByteOrderMark = hasByteOrderMark
            self.lineEnding = lineEnding
        }

        /// Plain UTF-8, no BOM, LF — the format for new or re-encoded files.
        public static let utf8 = Format(encoding: .utf8)
    }

    public struct Document: Sendable {
        /// Decoded text with the dominant line ending normalized to "\n".
        public let text: String
        public let format: Format

        /// Encoding the file was decoded with; saves should write back in this
        /// encoding so opening a Latin-1 file doesn't silently convert it.
        public var encoding: String.Encoding { format.encoding }

        public init(text: String, format: Format) {
            self.text = text
            self.format = format
        }
    }

    public enum ReadError: LocalizedError {
        case unreadable(URL, underlying: Error)
        case undecodable(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let underlying):
                return "Could not read “\(url.lastPathComponent)”: \(underlying.localizedDescription)"
            case .undecodable(let url):
                return "“\(url.lastPathComponent)” is not a text file PreviewMD can decode. "
                    + "It may be binary or use an unsupported encoding."
            }
        }
    }

    public enum WriteError: LocalizedError {
        /// The text contains characters the target encoding cannot represent
        /// (e.g. emoji in a Latin-1 file).
        case unencodable(URL, String.Encoding)
        case failed(URL, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .unencodable(let url, let encoding):
                return "“\(url.lastPathComponent)” contains characters that can't be saved in "
                    + "\(String.localizedName(of: encoding))."
            case .failed(let url, let underlying):
                return "Could not save “\(url.lastPathComponent)”: \(underlying.localizedDescription)"
            }
        }
    }

    // MARK: - Reading

    public static func read(from url: URL) throws -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReadError.unreadable(url, underlying: error)
        }
        return try decode(data, from: url)
    }

    public static func decode(_ data: Data, from url: URL) throws -> Document {
        if data.isEmpty {
            return Document(text: "", format: .utf8)
        }

        // Byte-order marks: decide the encoding up front and strip the mark.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let body = data.dropFirst(3)
            guard !body.contains(0), let text = String(data: body, encoding: .utf8) else {
                throw ReadError.undecodable(url)
            }
            return makeDocument(text, encoding: .utf8, bom: true)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            let encoding: String.Encoding = data.first == 0xFF ? .utf16LittleEndian : .utf16BigEndian
            let body = data.dropFirst(2)
            guard body.count % 2 == 0,
                  let text = String(data: body, encoding: encoding),
                  !text.utf16.contains(0) else {
                throw ReadError.undecodable(url)
            }
            return makeDocument(text, encoding: encoding, bom: true)
        }

        // No BOM: a NUL byte means binary (BOM-less UTF-16 is not supported).
        if data.contains(0) {
            throw ReadError.undecodable(url)
        }
        if let text = String(data: data, encoding: .utf8) {
            return makeDocument(text, encoding: .utf8, bom: false)
        }
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    NSNumber(value: String.Encoding.windowsCP1252.rawValue),
                    NSNumber(value: String.Encoding.isoLatin1.rawValue),
                    NSNumber(value: String.Encoding.shiftJIS.rawValue),
                ],
                .useOnlySuggestedEncodingsKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &usedLossy)
        guard raw != 0, let text = converted as String?, !usedLossy.boolValue,
              !text.utf16.contains(0) else {
            throw ReadError.undecodable(url)
        }
        return makeDocument(text, encoding: String.Encoding(rawValue: raw), bom: false)
    }

    private static func makeDocument(_ raw: String, encoding: String.Encoding, bom: Bool) -> Document {
        let ending = dominantLineEnding(in: raw) ?? .lf
        let text: String
        switch ending {
        case .lf: text = raw
        case .crlf: text = raw.replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
        case .cr: text = raw.replacingOccurrences(of: "\r", with: "\n", options: .literal)
        }
        return Document(text: text, format: Format(encoding: encoding, hasByteOrderMark: bom, lineEnding: ending))
    }

    /// The most common line ending in `text`, or nil if it has no line breaks.
    /// Ties resolve to LF.
    public static func dominantLineEnding(in text: String) -> LineEnding? {
        var lf = 0, crlf = 0, cr = 0
        var previousWasCR = false
        for unit in text.utf16 {
            if unit == 0x0A {
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
                previousWasCR = false
            } else if unit == 0x0D {
                cr += 1
                previousWasCR = true
            } else {
                previousWasCR = false
            }
        }
        if lf == 0 && crlf == 0 && cr == 0 { return nil }
        if crlf > lf && crlf >= cr { return .crlf }
        if cr > lf && cr > crlf { return .cr }
        return .lf
    }

    // MARK: - Writing

    /// Encodes `text` (with "\n" line breaks) into the bytes `format` describes.
    public static func encode(_ text: String, format: Format, for url: URL) throws -> Data {
        let body: String
        switch format.lineEnding {
        case .lf:
            body = text
        case .crlf:
            body = text
                .replacingOccurrences(of: "\r\n", with: "\n", options: .literal)
                .replacingOccurrences(of: "\n", with: "\r\n", options: .literal)
        case .cr:
            body = text
                .replacingOccurrences(of: "\r\n", with: "\r", options: .literal)
                .replacingOccurrences(of: "\n", with: "\r", options: .literal)
        }

        var data = Data()
        switch format.encoding {
        case .utf8:
            if format.hasByteOrderMark { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
            data.append(contentsOf: body.utf8)
        case .utf16LittleEndian, .utf16BigEndian:
            guard let encoded = body.data(using: format.encoding, allowLossyConversion: false) else {
                throw WriteError.unencodable(url, format.encoding)
            }
            if format.hasByteOrderMark {
                data.append(contentsOf: format.encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
            }
            data.append(encoded)
        default:
            guard let encoded = body.data(using: format.encoding, allowLossyConversion: false) else {
                throw WriteError.unencodable(url, format.encoding)
            }
            data.append(encoded)
        }
        return data
    }

    /// Encodes and writes `text` to `url` in `format`. See `writeData`.
    public static func write(_ text: String, to url: URL, format: Format) throws {
        let data = try encode(text, format: format, for: url)
        try writeData(data, to: url)
    }

    /// Atomically replaces the file at `url` (following symlinks) with `data`.
    ///
    /// The write is coordinated through `NSFileCoordinator` (iCloud Drive and
    /// other file presenters see a proper replace), and goes through
    /// `FileManager.replaceItemAt`, which keeps the original's permissions,
    /// extended attributes and creation date. A missing file is created.
    public static func writeData(_ data: Data, to url: URL) throws {
        let target = url.resolvingSymlinksInPath()
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: target, options: .forReplacing, error: &coordinationError
        ) { destination in
            do {
                try replaceContents(of: destination, with: data)
            } catch {
                writeError = error
            }
        }
        if let error = writeError ?? coordinationError {
            throw WriteError.failed(url, underlying: error)
        }
    }

    private static func replaceContents(of url: URL, with data: Data) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        // A replacement directory on the same volume; unavailable on some
        // network/FAT volumes, where a plain atomic write is the best we can do.
        guard let scratch = try? fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        else {
            try data.write(to: url, options: .atomic)
            return
        }
        defer { try? fm.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temp)
        _ = try fm.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [])
    }
}
