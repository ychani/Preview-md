import Foundation

/// Encoding-aware reading for markdown documents, shared by the app and the
/// Quick Look extension. UTF-8 is tried first; other encodings are detected
/// via `NSString.stringEncoding(for:...)`. Lossy decodes are rejected rather
/// than silently mangling the user's file.
public enum MarkdownDocumentIO {

    public struct Document {
        public let text: String
        /// Encoding the file was decoded with; saves should write back in this
        /// encoding so opening a Latin-1 file doesn't silently convert it.
        public let encoding: String.Encoding
    }

    public enum ReadError: LocalizedError {
        case unreadable(URL, underlying: Error)
        case undecodable(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url, let underlying):
                return "Could not read “\(url.lastPathComponent)”: \(underlying.localizedDescription)"
            case .undecodable(let url):
                return "“\(url.lastPathComponent)” is not a text file Preview-MD can decode. "
                    + "It may be binary or use an unsupported encoding."
            }
        }
    }

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
            return Document(text: "", encoding: .utf8)
        }
        if let text = String(data: data, encoding: .utf8) {
            return Document(text: text, encoding: .utf8)
        }
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    NSNumber(value: String.Encoding.utf16.rawValue),
                    NSNumber(value: String.Encoding.windowsCP1252.rawValue),
                    NSNumber(value: String.Encoding.isoLatin1.rawValue),
                    NSNumber(value: String.Encoding.shiftJIS.rawValue),
                ],
                .useOnlySuggestedEncodingsKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: &usedLossy)
        guard raw != 0, let text = converted as String?, !usedLossy.boolValue else {
            throw ReadError.undecodable(url)
        }
        return Document(text: text, encoding: String.Encoding(rawValue: raw))
    }
}
