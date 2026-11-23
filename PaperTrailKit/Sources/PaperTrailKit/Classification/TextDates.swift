import Foundation

/// Finds dates written in Dutch or English document text and returns them as yyyy-MM-dd.
/// Used to check that a date the model gives actually appears in the document.
public enum TextDates {
    public struct Match: Equatable, Sendable {
        /// yyyy-MM-dd
        public var date: String
        /// Start of the match in the searched text, in characters.
        public var offset: Int
    }

    static let months: [String: Int] = [
        "januari": 1, "january": 1, "jan": 1,
        "februari": 2, "february": 2, "feb": 2,
        "maart": 3, "march": 3, "mrt": 3, "mar": 3,
        "april": 4, "apr": 4,
        "mei": 5, "may": 5,
        "juni": 6, "june": 6, "jun": 6,
        "juli": 7, "july": 7, "jul": 7,
        "augustus": 8, "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9,
        "oktober": 10, "october": 10, "okt": 10, "oct": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]

    static func iso(year: Int, month: Int, day: Int) -> String? {
        var components = DateComponents()
        (components.year, components.month, components.day) = (year, month, day)
        let calendar = Calendar(identifier: .gregorian)
        guard (1900...2200).contains(year), let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// All dates in `text`, in order of appearance. Matching is case-insensitive.
    public static func all(in text: String) -> [Match] {
        let monthNames = months.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        // Each pattern yields (day, month, year) capture group numbers.
        let patterns: [(String, (Int, Int, Int))] = [
            (#"\b(\d{1,2})[-./](\d{1,2})[-./](\d{4})\b"#, (1, 2, 3)),
            (#"\b(\d{4})-(\d{2})-(\d{2})\b"#, (3, 2, 1)),
            (#"\b(\d{1,2})\s+("# + monthNames + #")\.?\s+(\d{4})\b"#, (1, 2, 3)),
            (#"\b("# + monthNames + #")\.?\s+(\d{1,2}),?\s+(\d{4})\b"#, (2, 1, 3)),
        ]
        let ns = text as NSString
        var found: [(location: Int, date: String)] = []
        for (pattern, groups) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                func part(_ group: Int) -> String { ns.substring(with: match.range(at: group)).lowercased() }
                let monthText = part(groups.1)
                guard let day = Int(part(groups.0)), let year = Int(part(groups.2)),
                      let month = Int(monthText) ?? months[monthText],
                      let date = iso(year: year, month: month, day: day)
                else { continue }
                found.append((match.range.location, date))
            }
        }
        return found.sorted { $0.location < $1.location }.map { item in
            let prefix = ns.substring(to: item.location)
            return Match(date: item.date, offset: prefix.count)
        }
    }

    /// The first date that starts within `window` characters after one of `labels`.
    /// Labels are tried in order, so earlier labels take priority.
    public static func date(after labels: [String], in text: String, window: Int = 30) -> String? {
        let lowered = text.lowercased()
        let dates = all(in: lowered)
        for label in labels {
            var searchStart = lowered.startIndex
            while let range = lowered.range(of: label, range: searchStart..<lowered.endIndex) {
                let end = lowered.distance(from: lowered.startIndex, to: range.upperBound)
                // Whole words only: "voor" must not match inside "voorwaarden".
                let letterBefore = range.lowerBound > lowered.startIndex && lowered[lowered.index(before: range.lowerBound)].isLetter
                let letterAfter = range.upperBound < lowered.endIndex && lowered[range.upperBound].isLetter
                if !letterBefore, !letterAfter, let hit = dates.first(where: { $0.offset >= end && $0.offset - end <= window }) {
                    return hit.date
                }
                searchStart = range.upperBound
            }
        }
        return nil
    }

    static let numberWords: [String: Int] = [
        "zeven": 7, "acht": 8, "tien": 10, "veertien": 14, "vijftien": 15, "eenentwintig": 21, "dertig": 30,
        "seven": 7, "eight": 8, "ten": 10, "fourteen": 14, "fifteen": 15, "twenty-one": 21, "thirty": 30,
    ]

    /// A payment term written as a number of days, such as "over te maken binnen 14 dagen",
    /// "betalingstermijn: 30 dagen", "within 30 days", "payment terms: 14 days" or "net 30".
    public static func paymentTermDays(in text: String) -> Int? {
        let number = #"(\d{1,3}|"# + numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
        let patterns = [
            // "binnen N dagen" only counts in a sentence about paying, not "levering binnen 3 dagen".
            #"\b(?:betalen|betaling|over\s+te\s+maken|overmaken|voldoen|voldaan|overgemaakt)\b[^.\n]{0,80}?\bbinnen\s+"# + number + #"\s+dagen"#,
            #"\bbinnen\s+"# + number + #"\s+dagen\b[^.\n]{0,40}?\b(?:betalen|over\s+te\s+maken|overmaken|voldoen|voldaan)"#,
            #"\bbetalingstermijn\b[^0-9a-z]{0,3}(?:van\s+|is\s+|bedraagt\s+)?"# + number + #"\s+dagen"#,
            #"\bwithin\s+"# + number + #"\s+days"#,
            #"\bpayment\s+terms?\b[^0-9a-z]{0,3}"# + number + #"\s+days"#,
            #"\bnet\s+(\d{1,3})\b"#,
        ]
        let ns = text.lowercased() as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length))
            else { continue }
            let value = ns.substring(with: match.range(at: 1))
            if let days = Int(value) ?? numberWords[value], (1...120).contains(days) { return days }
        }
        return nil
    }

    /// Adds `days` to a yyyy-MM-dd date.
    public static func adding(days: Int, to isoDate: String) -> String? {
        let parts = isoDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let end = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: end)
        return iso(year: c.year!, month: c.month!, day: c.day!)
    }
}
