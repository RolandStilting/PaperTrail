import Foundation

/// What the widgets show, written by the app into the App Group container. Widgets can't open
/// the app's data store, so the app keeps this small summary up to date.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public static let fileName = "WidgetSnapshot.json"
    /// Bills listed in the To Pay widget at most.
    public static let maxBills = 6

    public var updatedAt: Date
    /// The app lock is on: amounts and senders are left out, only counts are shown.
    public var hidesDetails: Bool
    public var reviewCount: Int
    public var openBillCount: Int
    public var openBillTotal: Double?
    public var overdueCount: Int
    public var expenseCount: Int
    public var expenseTotal: Double?
    /// Open bills, soonest due first; empty when details are hidden.
    public var bills: [Bill]

    public struct Bill: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var sender: String
        public var owner: String
        public var amount: Double?
        public var dueDate: Date?

        public init(id: UUID, sender: String, owner: String, amount: Double?, dueDate: Date?) {
            self.id = id
            self.sender = sender
            self.owner = owner
            self.amount = amount
            self.dueDate = dueDate
        }

        public func isOverdue(today: Date, calendar: Calendar = .current) -> Bool {
            (dueDate ?? .distantFuture) < calendar.startOfDay(for: today)
        }
    }

    public init(updatedAt: Date, hidesDetails: Bool, reviewCount: Int, openBillCount: Int, openBillTotal: Double?,
                overdueCount: Int, expenseCount: Int, expenseTotal: Double?, bills: [Bill]) {
        self.updatedAt = updatedAt
        self.hidesDetails = hidesDetails
        self.reviewCount = reviewCount
        self.openBillCount = openBillCount
        self.openBillTotal = openBillTotal
        self.overdueCount = overdueCount
        self.expenseCount = expenseCount
        self.expenseTotal = expenseTotal
        self.bills = bills
    }

    /// Builds the summary from the open bills and the expenses still to claim.
    public static func make(openBills: [Bill], expenseAmounts: [Double?], reviewCount: Int, hidesDetails: Bool,
                            now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let sorted = openBills.sorted { ($0.dueDate ?? .distantFuture, $0.sender) < ($1.dueDate ?? .distantFuture, $1.sender) }
        return WidgetSnapshot(
            updatedAt: now,
            hidesDetails: hidesDetails,
            reviewCount: reviewCount,
            openBillCount: openBills.count,
            openBillTotal: hidesDetails ? nil : ShortcutAnswers.total(openBills.map(\.amount)),
            overdueCount: openBills.filter { $0.isOverdue(today: now, calendar: calendar) }.count,
            expenseCount: expenseAmounts.count,
            expenseTotal: hidesDetails ? nil : ShortcutAnswers.total(expenseAmounts),
            bills: hidesDetails ? [] : Array(sorted.prefix(maxBills))
        )
    }

    /// Overdue count as it is today (the snapshot may be from yesterday).
    public func overdue(today: Date, calendar: Calendar = .current) -> Int {
        hidesDetails ? overdueCount : max(overdueCount, bills.filter { $0.isOverdue(today: today, calendar: calendar) }.count)
    }

    // MARK: File

    public static func url(in groupContainer: URL) -> URL { groupContainer.appending(path: fileName) }

    public func write(to groupContainer: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: Self.url(in: groupContainer), options: .atomic)
    }

    public static func read(from groupContainer: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url(in: groupContainer)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    /// Made-up content for the widget gallery and previews.
    public static func sample(now: Date = .now) -> WidgetSnapshot {
        let day: TimeInterval = 24 * 60 * 60
        return make(openBills: [
            Bill(id: UUID(), sender: "Voorbeeld Energie", owner: "Private", amount: 142.37, dueDate: now.addingTimeInterval(-3 * day)),
            Bill(id: UUID(), sender: "Schildersbedrijf Voorbeeld", owner: "Company1", amount: 853.66, dueDate: now.addingTimeInterval(4 * day)),
            Bill(id: UUID(), sender: "Example Cloud", owner: "Company1", amount: 29, dueDate: now.addingTimeInterval(12 * day)),
        ], expenseAmounts: [12.10], reviewCount: 2, hidesDetails: false, now: now)
    }
}

/// Links from widgets into the app.
public enum WidgetLink {
    public static let toPay = URL(string: "papertrail://topay")!
    public static let review = URL(string: "papertrail://review")!
    public static let expenses = URL(string: "papertrail://expenses")!

    public static func bill(_ id: UUID) -> URL { URL(string: "papertrail://bill/\(id.uuidString)")! }
}
