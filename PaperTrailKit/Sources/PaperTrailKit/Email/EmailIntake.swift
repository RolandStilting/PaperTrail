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

    /// PDF attachments and attached images; if there are none, the HTML body, else the text body.
    /// Inline images without an attachment disposition (logos in HTML mail) are ignored.
    public static func documents(in message: EmailMessage) -> [EmailDocument] {
        var documents: [EmailDocument] = []
        for (index, part) in message.leaves.enumerated() where !part.body.isEmpty {
            let name = part.filename ?? ""
            let ext = FileNamer.splitExtension(name).ext.lowercased()
            let isPDF = part.contentType == "application/pdf"
                || (ext == "pdf" && (part.contentType == "application/octet-stream" || part.isAttachment))
            if isPDF {
                documents.append(.pdf(name: name.isEmpty ? "Attachment \(index + 1).pdf" : name, data: part.body))
            } else if part.isAttachment, part.contentType.hasPrefix("image/") || imageExtensions.contains(ext) {
                documents.append(.image(name: name.isEmpty ? "Image \(index + 1).\(part.contentType.split(separator: "/").last ?? "jpg")" : name, data: part.body))
            }
        }
        if !documents.isEmpty { return documents }

        let bodies = message.leaves.filter { !$0.isAttachment }
        if let html = bodies.first(where: { $0.contentType == "text/html" }) {
            return [.html(html.text)]
        }
        if let text = bodies.first(where: { $0.contentType == "text/plain" }), !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.text(text.text)]
        }
        return []
    }

    /// A short label for file names: the subject, else the sender.
    public static func label(for message: EmailMessage) -> String {
        let subject = message.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? message.from : subject
    }
}
