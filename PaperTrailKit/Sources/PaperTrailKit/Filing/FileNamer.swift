import Foundation

/// Builds archive file names of the form `YYYY-MM-DD Sender - Description.pdf`.
public struct FileNamer: Sendable {
    public static let fileExtension = "pdf"
    public static let fallbackSender = "Unknown"
    public static let fallbackDescription = "Document"

    /// Characters that are not allowed in file or folder names.
    public static let forbiddenCharacters: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]

    public var maxDescriptionWords: Int
    public var maxSenderLength: Int
    public var calendar: Calendar

    /// - Parameter calendar: Used to turn the received date into a day. Defaults to a
    ///   Gregorian calendar in the current time zone.
    public init(maxDescriptionWords: Int = 6, maxSenderLength: Int = 40, calendar: Calendar? = nil) {
        self.maxDescriptionWords = maxDescriptionWords
        self.maxSenderLength = maxSenderLength
        self.calendar = calendar ?? FileNamer.defaultCalendar()
    }

    public static func defaultCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// The file name without collision suffix, e.g. `2026-03-01 KPN - Mobile invoice March.pdf`.
    public func fileName(receivedDate: Date, sender: String, description: String) -> String {
        "\(baseName(receivedDate: receivedDate, sender: sender, description: description)).\(Self.fileExtension)"
    }

    /// The file name without extension.
    public func baseName(receivedDate: Date, sender: String, description: String) -> String {
        "\(dateString(receivedDate)) \(cleanSender(sender)) - \(cleanDescription(description))"
    }

    public func dateString(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    public func cleanSender(_ sender: String) -> String {
        var cleaned = Self.sanitizeComponent(SenderNormalizer.normalize(sender))
        // " - " separates sender from description, so it may not appear in the sender.
        cleaned = cleaned.replacingOccurrences(of: " - ", with: " ")
        cleaned = String(cleaned.prefix(maxSenderLength))
        cleaned = Self.trimEdges(cleaned)
        return cleaned.isEmpty ? Self.fallbackSender : cleaned
    }

    public func cleanDescription(_ description: String) -> String {
        let words = Self.sanitizeComponent(description).split(separator: " ")
        let cleaned = Self.trimEdges(words.prefix(maxDescriptionWords).joined(separator: " "))
        return cleaned.isEmpty ? Self.fallbackDescription : cleaned
    }

    /// Makes a string safe as a single file or folder name: forbidden and control characters
    /// become spaces, runs of whitespace collapse to one space, and leading dots plus trailing
    /// dots and spaces are removed. May return an empty string.
    public static func sanitizeComponent(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if forbiddenCharacters.contains(character)
                || character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                || character.isWhitespace {
                result.append(" ")
            } else {
                result.append(character)
            }
        }
        let collapsed = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return trimEdges(collapsed)
    }

    static func trimEdges(_ text: String) -> String {
        var result = Substring(text)
        while let first = result.first, first == "." || first == " " { result.removeFirst() }
        while let last = result.last, last == "." || last == " " { result.removeLast() }
        return String(result)
    }

    /// Returns `fileName` if `exists` reports it free, otherwise `name (2).pdf`, `name (3).pdf`, ...
    /// Comparison is left to `exists`; callers on APFS/iCloud should treat names case-insensitively.
    public static func uniqueFileName(_ fileName: String, maxAttempts: Int = 999, exists: (String) throws -> Bool) rethrows -> String? {
        if try !exists(fileName) { return fileName }
        let (base, ext) = splitExtension(fileName)
        for number in 2...max(2, maxAttempts) {
            let candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            if try !exists(candidate) { return candidate }
        }
        return nil
    }

    static func splitExtension(_ fileName: String) -> (base: String, ext: String) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return (fileName, "") }
        return (String(fileName[..<dot]), String(fileName[fileName.index(after: dot)...]))
    }
}
