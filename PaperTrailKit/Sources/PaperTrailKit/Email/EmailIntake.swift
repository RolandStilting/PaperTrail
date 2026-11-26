import Foundation

/// What Paper Trail takes from one email.
public enum EmailDocument: Equatable, Sendable {
    case pdf(name: String, data: Data)
    case image(name: String, data: Data)
    /// No attachments: the email itself becomes the document (rendered to PDF by the app).
    case html(String)
    case text(String)
}

public enum EmailIntake {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    /// Limits for one email, which can come from anyone: at most this many documents, and
    /// attachments within these sizes. Anything beyond is skipped and reported.
    public static let maxDocuments = 20
    public static let maxPDFBytes = 50_000_000
    public static let maxImageBytes = 30_000_000
    static let minPDFBytes = 8

    /// The documents to file from one email, and what was skipped (user-facing reasons).
    public struct Selection: Equatable, Sendable {
        public var documents: [EmailDocument] = []
        public var skipped: [String] = []
    }

    /// PDF attachments and attached images; if there are none, the HTML body, else the text body.
    /// Inline images without an attachment disposition (logos in HTML mail) are ignored.
    public static func documents(in message: EmailMessage) -> [EmailDocument] {
        select(in: message).documents
    }

    public static func select(in message: EmailMessage) -> Selection {
        var selection = Selection()
        var tooMany = 0
        for (index, part) in message.leaves.enumerated() where !part.body.isEmpty {
            let name = part.filename ?? ""
            let ext = FileNamer.splitExtension(name).ext.lowercased()
            let isPDF = part.contentType == "application/pdf"
                || (ext == "pdf" && (part.contentType == "application/octet-stream" || part.isAttachment))
            let isImage = !isPDF && part.isAttachment && (part.contentType.hasPrefix("image/") || imageExtensions.contains(ext))
            guard isPDF || isImage else { continue }
            let shownName = name.isEmpty ? String(localized: "attachment \(index + 1)", bundle: .module) : name
            if isPDF {
                guard looksLikePDF(part.body) else {
                    selection.skipped.append(String(localized: "\"\(shownName)\" is not a valid PDF.", bundle: .module))
                    continue
                }
                guard part.body.count <= maxPDFBytes else {
                    selection.skipped.append(String(localized: "\"\(shownName)\" is larger than 50 MB.", bundle: .module))
                    continue
                }
            } else if part.body.count > maxImageBytes {
                selection.skipped.append(String(localized: "\"\(shownName)\" is larger than 30 MB.", bundle: .module))
                continue
            }
            guard selection.documents.count < maxDocuments else { tooMany += 1; continue }
            if isPDF {
                selection.documents.append(.pdf(name: name.isEmpty ? "Attachment \(index + 1).pdf" : name, data: part.body))
            } else {
                selection.documents.append(.image(name: name.isEmpty ? "Image \(index + 1).\(part.contentType.split(separator: "/").last ?? "jpg")" : name, data: part.body))
            }
        }
        if tooMany > 0 {
            selection.skipped.append(String(localized: "\(tooMany) more attachments were skipped: Paper Trail takes at most \(maxDocuments) from one email.", bundle: .module))
        }
        if !selection.documents.isEmpty { return selection }

        let bodies = message.leaves.filter { !$0.isAttachment }
        if let html = bodies.first(where: { $0.contentType == "text/html" }) {
            selection.documents = [.html(html.text)]
        } else if let text = bodies.first(where: { $0.contentType == "text/plain" }), !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection.documents = [.text(text.text)]
        }
        return selection
    }

    /// A real PDF starts with "%PDF-" (some files have a few bytes of junk before it).
    static func looksLikePDF(_ data: Data) -> Bool {
        guard data.count >= minPDFBytes else { return false }
        return data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    /// The received date for an email's documents. The Date header is written by the sender,
    /// so it's only used when it's plausible: not in the future and at most 30 days old.
    public static func receivedDate(header: Date?, now: Date = .now) -> Date {
        guard let header, header <= now.addingTimeInterval(60 * 60), header >= now.addingTimeInterval(-30 * 24 * 60 * 60) else { return now }
        return min(header, now)
    }

    /// A short label for file names: the subject, else the sender.
    public static func label(for message: EmailMessage) -> String {
        let subject = message.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? message.from : subject
    }
}
