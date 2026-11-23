import Foundation

/// Payment details of a bill, stored with the document and used for Reminders (phase 4).
public struct BillDetails: Sendable, Hashable {
    public var isUnpaid: Bool
    public var amount: Double?
    public var dueDate: Date?
    /// IBAN without spaces.
    public var iban: String
    public var reference: String

    public init(isUnpaid: Bool = false, amount: Double? = nil, dueDate: Date? = nil, iban: String = "", reference: String = "") {
        self.isUnpaid = isUnpaid
        self.amount = amount
        self.dueDate = dueDate
        self.iban = iban
        self.reference = reference
    }

    /// True when there is nothing worth storing.
    public var isEmpty: Bool {
        !isUnpaid && amount == nil && dueDate == nil && iban.isEmpty && reference.isEmpty
    }
}

/// What the app suggests for one document, ready to prefill the filing screen.
/// Empty strings and nil mean "no suggestion"; the user always confirms.
public struct Proposal: Sendable, Hashable {
    public var sender: String
    public var documentDate: Date?
    /// A category name from the settings, or empty.
    public var category: String
    public var description: String
    public var bill: BillDetails

    public init(sender: String = "", documentDate: Date? = nil, category: String = "", description: String = "", bill: BillDetails = BillDetails()) {
        self.sender = sender
        self.documentDate = documentDate
        self.category = category
        self.description = description
        self.bill = bill
    }

    /// Converts checked model output. `calendar` (default: Gregorian, current time zone)
    /// decides which day a yyyy-MM-dd string means.
    public init(_ extraction: ModelExtraction, calendar: Calendar? = nil) {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let namer = FileNamer(calendar: calendar)
        self.init(
            sender: namer.cleanSender(extraction.sender),
            documentDate: Self.date(extraction.documentDate, calendar: calendar),
            category: extraction.category,
            description: namer.cleanDescription(extraction.description),
            bill: BillDetails(
                isUnpaid: extraction.isUnpaidBill,
                amount: extraction.amount > 0 ? (extraction.amount * 100).rounded() / 100 : nil,
                dueDate: Self.date(extraction.dueDate, calendar: calendar),
                iban: extraction.iban,
                reference: extraction.reference.trimmingCharacters(in: .whitespaces)
            )
        )
    }

    /// Parses yyyy-MM-dd as noon on that day in `calendar`, so time zones can't shift the day.
    public static func date(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == parts[0], check.month == parts[1], check.day == parts[2] else { return nil }
        return date
    }
}

extension ModelExtractor {
    /// Checked model output as a proposal for the filing screen. Runs only on the device.
    public func proposal(for text: String, calendar: Calendar? = nil) async throws -> Proposal {
        Proposal(try await propose(from: text), calendar: calendar)
    }
}
