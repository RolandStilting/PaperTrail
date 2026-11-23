import Foundation

/// File names in `Paper Trail/Needs Review/`. The folder itself is the queue: whatever PDF is
/// in it waits for review, so the queue survives reinstalls and syncs like any other file.
public enum ReviewQueueNames {
    /// "2026-11-23 1432 Scan.pdf" or "2026-11-23 1432 <original name>.pdf". The date is
    /// when the document came in and becomes its received date when filed.
    public static func fileName(savedAt date: Date, originalName: String?, calendar: Calendar? = nil) -> String {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        let base = originalName.map { FileNamer.splitExtension($0).base } ?? ""
        let cleaned = FileNamer.sanitizeComponent(base)
        let label = cleaned.isEmpty ? String(localized: "Scan", bundle: .module) : String(cleaned.prefix(60))
        return "\(stamp) \(label).pdf"
    }

    /// The PDF name for a directory entry, or nil if the entry is not a queued PDF.
    /// iCloud shows files that are not downloaded yet as ".<name>.icloud".
    public static func itemName(forDirectoryEntry entry: String) -> String? {
        var name = entry
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            name = String(name.dropFirst().dropLast(".icloud".count))
        } else if name.hasPrefix(".") {
            return nil
        }
        return name.lowercased().hasSuffix(".pdf") ? name : nil
    }

    /// The day a queued file came in, read from the start of its name.
    public static func savedDate(fromFileName name: String, calendar: Calendar? = nil) -> Date? {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let parts = name.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard name.count >= 10, parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return date
    }
}

/// What to do with an entry in `Paper Trail/Inbox/`.
public enum InboxEntry: Equatable, Sendable {
    /// A PDF: move it to Needs Review as it is.
    case pdf(String)
    /// An image: convert to PDF, then move to Needs Review.
    case image(String)
    /// iCloud has only a placeholder; download it and pick it up next time.
    case notDownloaded(String)
    /// A file Paper Trail can't read; it stays in Inbox and the user is told.
    case unsupported(String)
    /// Hidden system files such as .DS_Store.
    case ignored

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]

    public init(directoryEntry entry: String) {
        if entry.hasPrefix("."), entry.hasSuffix(".icloud"), entry.count > ".x.icloud".count - 1 {
            self = .notDownloaded(String(entry.dropFirst().dropLast(".icloud".count)))
            return
        }
        guard !entry.hasPrefix(".") else {
            self = .ignored
            return
        }
        let ext = FileNamer.splitExtension(entry).ext.lowercased()
        if ext == "pdf" {
            self = .pdf(entry)
        } else if Self.imageExtensions.contains(ext) {
            self = .image(entry)
        } else {
            self = .unsupported(entry)
        }
    }
}
