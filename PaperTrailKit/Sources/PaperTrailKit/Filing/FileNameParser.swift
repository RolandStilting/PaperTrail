import Foundation

/// Reads the parts back out of an archive file name, for rebuilding the index from the files.
public struct ParsedFileName: Sendable, Hashable {
    public var receivedDate: Date
    public var sender: String
    public var description: String
    /// The collision number, e.g. 2 for `... (2).pdf`; nil when there is none.
    public var duplicateNumber: Int?
}

public enum FileNameParser {
    /// Returns nil when the name does not follow `YYYY-MM-DD Sender - Description.pdf`.
    public static func parse(_ fileName: String, calendar: Calendar = FileNamer.defaultCalendar()) -> ParsedFileName? {
        var (base, ext) = FileNamer.splitExtension(fileName)
        guard ext.lowercased() == FileNamer.fileExtension else { return nil }

        var duplicateNumber: Int?
        if let match = base.wholeMatch(of: /(.+) \((\d+)\)/), let number = Int(match.2) {
            base = String(match.1)
            duplicateNumber = number
        }

        guard let match = base.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2}) (.+?) - (.+)/),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3) else { return nil }

        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else { return nil }

        return ParsedFileName(receivedDate: date, sender: String(match.4), description: String(match.5), duplicateNumber: duplicateNumber)
    }
}
