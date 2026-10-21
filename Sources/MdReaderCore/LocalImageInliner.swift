import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One local image to hand to Quick Look as a `cid:` attachment.
public struct InlinedImage: Equatable {
    public let data: Data
    public let contentType: UTType

    public init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }
}

/// Makes relative local images work in Quick Look's data-based preview.
///
/// Quick Look renders the returned HTML itself and the extension's sandbox
/// only covers the previewed file, so `<img src="img/a.png">` can't load
/// from disk. This post-pass over the rendered (and sanitized) HTML reads
/// eligible images itself and rewrites their `src` to `cid:img-N`; the
/// caller returns the bytes as `QLPreviewReplyAttachment`s under those IDs.
///
/// Only `<img>` start tags are touched (markdown images, raw HTML `<img>`,
/// and `![[image.png]]` embeds). A `src` is eligible when it is a relative
/// path with no scheme, not `//host`, not `#…` and not absolute, that stays
/// inside the previewed file's folder: no `..` segments, and with symlinks
/// resolved the file must still be inside the folder
/// (`MarkdownRenderBridge.resolveImageFile`, the same policy the app's
/// `previewmd-local:` scheme uses). The bytes must really be an image
/// (ImageIO for raster formats, an `<svg>` root element for SVG).
/// Everything else is left as is — the Quick Look CSP (`img-src cid: data:`)
/// blocks it.
public enum LocalImageInliner {

    public struct Limits: Equatable {
        /// Largest single image that is inlined.
        public var maxImageBytes: Int
        /// Budget for all inlined images together.
        public var maxTotalBytes: Int
        /// Most distinct images inlined.
        public var maxImages: Int

        public init(maxImageBytes: Int, maxTotalBytes: Int, maxImages: Int) {
            self.maxImageBytes = maxImageBytes
            self.maxTotalBytes = maxTotalBytes
            self.maxImages = maxImages
        }

        /// 4 MB per image, 16 MB in total, at most 64 images.
        public static let quickLook = Limits(
            maxImageBytes: 4 * 1024 * 1024, maxTotalBytes: 16 * 1024 * 1024, maxImages: 64)
    }

    public struct Result {
        public let html: String
        /// Content-ID (`img-N`, referenced as `cid:img-N`) → image.
        public let attachments: [String: InlinedImage]
        /// `<img>` tags whose image was left out because it was over a
        /// size or count budget. They keep their `alt` and get a title.
        public let skipped: Int
        /// `<img>` tags with a local-looking `src` that the path or content
        /// policy refused (or that don't exist).
        public let refused: Int
    }

    /// Reads a file's bytes. Injected so tests can observe reads.
    public typealias Reader = (URL) throws -> Data

    /// Attribute marking `![[image.png]]` embeds from markdown-extensions.js
    /// (static mode). Embeds are also looked up in `embedFolders`.
    static let embedAttribute = "data-previewmd-embed"

    /// Obsidian-style attachment folders tried, in order, after the
    /// document's own folder for an image embed. Bounded: no recursive scan.
    static let embedFolders = ["attachments", "assets", "images"]

    static let tooLargeTitle = "Image too large to preview"
    static let notFoundTitle = "Image not found"

    public static func inline(
        html: String,
        documentFolder: URL,
        limits: Limits = .quickLook,
        reader: @escaping Reader = { try Data(contentsOf: $0) }
    ) -> Result {
        var state = State(limits: limits, folder: documentFolder, reader: reader)
        let out = MarkdownHTMLRenderer.replaceMatches(
            in: html, pattern: MarkdownHTMLRenderer.startTag
        ) { tag in
            isImageTag(tag) ? state.rewrite(tag) : tag
        }
        return Result(html: out, attachments: state.attachments,
                      skipped: state.skipped, refused: state.refused)
    }

    // MARK: - Per-render state

    private enum Outcome {
        case inlined(cid: String)
        case tooLarge
        case refused
    }

    private struct State {
        let limits: Limits
        let folder: URL
        let reader: Reader
        var attachments: [String: InlinedImage] = [:]
        var outcomeByPath: [String: Outcome] = [:]
        var totalBytes = 0
        var skipped = 0
        var refused = 0

        init(limits: Limits, folder: URL, reader: @escaping Reader) {
            self.limits = limits
            self.folder = folder
            self.reader = reader
        }

        mutating func rewrite(_ tag: String) -> String {
            var src: String?
            var isEmbed = false
            _ = MarkdownHTMLRenderer.replaceMatches(in: tag, pattern: MarkdownHTMLRenderer.attribute) { attr in
                if let (name, value) = MarkdownHTMLRenderer.attributeParts(attr) {
                    if name == "src", src == nil { src = value }
                    if name == embedAttribute { isEmbed = true }
                }
                return attr
            }
            var outcome = Outcome.refused
            switch src.map(LocalImageInliner.classify) ?? .notLocal {
            case .notLocal:
                return isEmbed ? LocalImageInliner.dropAttributes([embedAttribute], from: tag) : tag
            case .refused:
                break
            case .local(let segments):
                let candidates = isEmbed
                    ? [segments] + embedFolders.map { [$0] + segments }
                    : [segments]
                for candidate in candidates {
                    if let file = MarkdownRenderBridge.resolveImageFile(segments: candidate, inside: folder) {
                        outcome = load(file)
                        break
                    }
                }
            }
            switch outcome {
            case .inlined(let cid):
                return LocalImageInliner.replaceSource(
                    in: tag, with: "src=\"cid:\(cid)\"", dropping: ["src", "srcset", embedAttribute])
            case .tooLarge:
                skipped += 1
                return LocalImageInliner.replaceSource(
                    in: tag, with: "title=\"\(tooLargeTitle)\"",
                    dropping: ["src", "srcset", "title", embedAttribute])
            case .refused:
                refused += 1
                guard isEmbed else { return tag }
                return LocalImageInliner.replaceSource(
                    in: tag, with: "title=\"\(notFoundTitle)\"",
                    dropping: ["src", "srcset", "title", embedAttribute])
            }
        }

        /// Reads and verifies one resolved file, deduplicated by path.
        private mutating func load(_ file: (path: String, ext: String, size: Int)) -> Outcome {
            if let known = outcomeByPath[file.path] { return known }
            let outcome = readAndVerify(file)
            outcomeByPath[file.path] = outcome
            return outcome
        }

        private mutating func readAndVerify(_ file: (path: String, ext: String, size: Int)) -> Outcome {
            func fits(_ size: Int) -> Bool {
                size <= limits.maxImageBytes
                    && totalBytes + size <= limits.maxTotalBytes
                    && attachments.count < limits.maxImages
            }
            // Size check before reading.
            guard fits(file.size) else { return .tooLarge }
            guard let data = try? reader(URL(fileURLWithPath: file.path)) else { return .refused }
            guard fits(data.count) else { return .tooLarge }  // grew since stat
            guard let type = LocalImageInliner.verifiedType(of: data, ext: file.ext) else { return .refused }
            let cid = "img-\(attachments.count + 1)"
            attachments[cid] = InlinedImage(data: data, contentType: type)
            totalBytes += data.count
            return .inlined(cid: cid)
        }
    }

    // MARK: - Tags

    static func isImageTag(_ tag: String) -> Bool {
        tag.range(of: #"^<img[\s/>]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Removes every attribute named in `names` (case-insensitive), with the
    /// whitespace before it.
    static func dropAttributes(_ names: Set<String>, from tag: String) -> String {
        MarkdownHTMLRenderer.replaceMatches(in: tag, pattern: #"\s*"# + MarkdownHTMLRenderer.attribute) { attr in
            guard let (name, _) = MarkdownHTMLRenderer.attributeParts(attr) else { return attr }
            return names.contains(name) ? "" : attr
        }
    }

    /// Drops `names` and inserts `attribute` right after `<img`.
    static func replaceSource(in tag: String, with attribute: String, dropping names: Set<String>) -> String {
        let stripped = dropAttributes(names, from: tag)
        let head = stripped.index(stripped.startIndex, offsetBy: 4)  // "<img"
        return String(stripped[..<head]) + " " + attribute + String(stripped[head...])
    }

    // MARK: - Source policy

    enum SourceKind: Equatable {
        /// A URL with a scheme (`https:`, `data:`, `file:`…), a fragment, or
        /// empty: not a local file reference; left alone.
        case notLocal
        /// A local path the policy refuses: absolute, `//host`, `..`.
        case refused
        /// Path components relative to the document's folder.
        case local([String])
    }

    /// Classifies a `src` attribute value (entities still encoded).
    /// `.` segments are dropped (`./img/a.png`); any `..` segment refuses
    /// the whole path, even one that would stay inside the folder.
    static func classify(_ rawValue: String) -> SourceKind {
        var value = decodeHTMLEntities(rawValue)
        // URL parsers drop tabs/newlines anywhere and trim C0 + space.
        value = String(String.UnicodeScalarView(
            value.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }))
        value = value.trimmingCharacters(
            in: CharacterSet(charactersIn: Unicode.Scalar(UInt8(0))...Unicode.Scalar(UInt8(0x20))))
        guard !value.isEmpty, !value.hasPrefix("#") else { return .notLocal }
        // Any scheme (`file:`, `https:`, `data:`, `cid:`, `c:`…).
        if value.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil {
            return .notLocal
        }
        // Absolute, `//host`, or backslashes (which URL parsers treat as `/`).
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else {
            return .refused
        }
        if let cut = value.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(value[..<cut])
        }
        let decoded = value.removingPercentEncoding ?? value
        guard !decoded.contains("\0"), !decoded.hasPrefix("/") else { return .refused }
        var segments: [String] = []
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." { return .refused }
            segments.append(String(segment))
        }
        return segments.isEmpty ? .refused : .local(segments)
    }

    /// Decodes character references in an attribute value in one pass:
    /// numeric ones and the named ones marked and HTML authors use in URLs.
    /// Unknown named references are left as written.
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": "\u{A0}", "colon": ":", "tab": "\t", "newline": "\n",
        ]
        return MarkdownHTMLRenderer.replaceMatches(
            in: text, pattern: #"&(#x[0-9a-f]+|#[0-9]+|[a-z]+);?"#
        ) { ref in
            let body = ref.dropFirst().filter { $0 != ";" }
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let code = digits.lowercased().hasPrefix("x")
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits, radix: 10)
                return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
            return named[body.lowercased()] ?? ref
        }
    }

    // MARK: - Content checks

    /// The image type the bytes really are, or nil if they aren't an image
    /// (a text file renamed `.png`). SVG is checked by its root element.
    static func verifiedType(of data: Data, ext: String) -> UTType? {
        if ext == "svg" {
            return hasSVGRoot(data) ? .svg : nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier), type.conforms(to: .image) else { return nil }
        return type
    }

    /// True if the document's root element is `<svg>`. External entities
    /// are never resolved; parsing stops at the root element.
    static func hasSVGRoot(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        let sniffer = RootElementSniffer()
        parser.delegate = sniffer
        parser.parse()
        return sniffer.root?.lowercased() == "svg"
    }

    private final class RootElementSniffer: NSObject, XMLParserDelegate {
        var root: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if root == nil { root = elementName }
            parser.abortParsing()
        }
    }
}
