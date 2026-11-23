import CoreFoundation
import Foundation

/// One part of a MIME message (RFC 2045/2046). Leaf parts hold decoded bytes.
public struct MIMEPart: Sendable {
    /// Header names are lowercased; values are unfolded.
    public var headers: [(name: String, value: String)]
    /// e.g. "application/pdf", lowercased.
    public var contentType: String
    /// Content-Type parameters such as charset, name, boundary (keys lowercased).
    public var parameters: [String: String]
    public var disposition: String
    public var filename: String?
    /// Transfer-decoded body (base64 / quoted-printable undone).
    public var body: Data
    public var children: [MIMEPart]

    public func header(_ name: String) -> String? {
        headers.first { $0.name == name.lowercased() }?.value
    }

    public var isAttachment: Bool { disposition == "attachment" }

    /// The body as text, using the part's charset (UTF-8 if none or unknown).
    public var text: String {
        MIMEParser.decodeText(body, charset: parameters["charset"])
    }
}

/// A parsed email with the details Paper Trail needs.
public struct EmailMessage: Sendable {
    public var root: MIMEPart
    public var from: String
    public var subject: String
    public var date: Date?

    /// Every leaf part, depth first.
    public var leaves: [MIMEPart] {
        func walk(_ part: MIMEPart) -> [MIMEPart] { part.children.isEmpty ? [part] : part.children.flatMap(walk) }
        return walk(root)
    }
}

/// Parses raw RFC 5322 messages. Bytes outside headers are handled as ISO Latin-1 strings
/// internally, which maps every byte one to one, so binary attachments survive intact.
public enum MIMEParser {
    public static func parse(_ data: Data) -> EmailMessage {
        let root = parsePart(String(decoding: data, asLatin1: true))
        return EmailMessage(
            root: root,
            from: decodeHeaderWords(root.header("from") ?? ""),
            subject: decodeHeaderWords(root.header("subject") ?? ""),
            date: root.header("date").flatMap(parseDate)
        )
    }

    static func parsePart(_ raw: String) -> MIMEPart {
        let (headerText, bodyText) = splitHeaderAndBody(raw)
        let headers = parseHeaders(headerText)
        func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }

        let (type, parameters) = parseParameterized(header("content-type") ?? "text/plain; charset=us-ascii")
        let (disposition, dispositionParameters) = parseParameterized(header("content-disposition") ?? "")
        let filename = (dispositionParameters["filename"] ?? parameters["name"]).map(decodeHeaderWords)

        var part = MIMEPart(headers: headers, contentType: type.isEmpty ? "text/plain" : type, parameters: parameters,
                            disposition: disposition, filename: filename, body: Data(), children: [])

        if part.contentType.hasPrefix("multipart/"), let boundary = parameters["boundary"], !boundary.isEmpty {
            part.children = splitMultipart(bodyText, boundary: boundary).map(parsePart)
        } else if part.contentType == "message/rfc822" {
            part.children = [parsePart(bodyText)]
        } else {
            let encoding = (header("content-transfer-encoding") ?? "7bit").lowercased().trimmingCharacters(in: .whitespaces)
            part.body = decodeTransfer(bodyText, encoding: encoding)
        }
        return part
    }

    static func splitHeaderAndBody(_ raw: String) -> (String, String) {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = raw.range(of: separator) {
                return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
            }
        }
        return (raw, "")
    }

    static func parseHeaders(_ text: String) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for line in text.components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) {
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                result.append((name, value))
            }
        }
        return result
    }

    /// "text/plain; charset=\"utf-8\"; name=a.pdf" → ("text/plain", ["charset": "utf-8", "name": "a.pdf"]).
    /// Supports RFC 2231 `name*=utf-8''…` for the common single-segment case.
    static func parseParameterized(_ value: String) -> (String, [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for character in value {
            if character == "\"" { inQuotes.toggle() }
            if character == ";", !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        let main = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var value = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if key.hasSuffix("*") {
                key.removeLast()
                // charset'language'percent-encoded
                let segments = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if segments.count == 3, let decoded = String(segments[2]).removingPercentEncoding {
                    value = decoded
                }
            }
            parameters[key] = value
        }
        return (main, parameters)
    }

    static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        var current: [String]?
        // The line break before a delimiter belongs to the delimiter (RFC 2046), so it is dropped.
        func finish(_ lines: [String]) -> String {
            var joined = lines.joined(separator: "\n")
            if joined.hasSuffix("\r") { joined.removeLast() }
            return joined
        }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if trimmed.hasPrefix(delimiter) {
                if let current { parts.append(finish(current)) }
                if trimmed.hasPrefix(delimiter + "--") { return parts }
                current = []
            } else {
                current?.append(line)
            }
        }
        if let current { parts.append(finish(current)) }
        return parts
    }

    static func decodeTransfer(_ text: String, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let compact = text.filter { !$0.isWhitespace }
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(text)
        default:
            var body = text
            // "\r\n" is one Character in Swift, so a single removeLast drops the whole line break.
            if body.hasSuffix("\r\n") || body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast() }
            return Data(latin1: body)
        }
    }

    static func decodeQuotedPrintable(_ text: String, underscoreIsSpace: Bool = false) -> Data {
        var bytes: [UInt8] = []
        let input = Array(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "=") {
                if index + 1 < input.count, input[index + 1] == UInt8(ascii: "\n") {
                    index += 2
                    continue
                }
                if index + 2 < input.count, input[index + 1] == UInt8(ascii: "\r"), input[index + 2] == UInt8(ascii: "\n") {
                    index += 3
                    continue
                }
                if index + 2 < input.count, let value = UInt8(String(bytes: input[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) {
                    bytes.append(value)
                    index += 3
                    continue
                }
            }
            bytes.append(underscoreIsSpace && byte == UInt8(ascii: "_") ? UInt8(ascii: " ") : byte)
            index += 1
        }
        return Data(bytes)
    }

    public static func decodeText(_ data: Data, charset: String?) -> String {
        if let charset, !charset.isEmpty {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047: "=?utf-8?Q?Factuur_maart?=" → "Factuur maart". Whitespace between
    /// adjacent encoded words is dropped, as the RFC requires.
    public static func decodeHeaderWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let ns = value as NSString
        var result = ""
        var last = 0
        var previousWasEncoded = false
        for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: match.range.location - last))
            if !(previousWasEncoded && between.allSatisfy(\.isWhitespace)) { result += between }
            let charset = ns.substring(with: match.range(at: 1))
            let mode = ns.substring(with: match.range(at: 2)).lowercased()
            let text = ns.substring(with: match.range(at: 3))
            let bytes = mode == "b" ? (Data(base64Encoded: text) ?? Data()) : decodeQuotedPrintable(text, underscoreIsSpace: true)
            result += decodeText(bytes, charset: charset.split(separator: "*").first.map(String.init))
            last = match.range.location + match.range.length
            previousWasEncoded = true
        }
        result += ns.substring(from: last)
        return result
    }

    static func parseDate(_ value: String) -> Date? {
        let cleaned = value.replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }
}

extension String {
    init(decoding data: Data, asLatin1: Bool) {
        self = String(data: data, encoding: .isoLatin1) ?? ""
    }
}

extension Data {
    init(latin1 string: String) {
        self = string.data(using: .isoLatin1) ?? Data(string.utf8)
    }
}
