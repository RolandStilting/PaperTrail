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
    /// Optional so a snapshot from an older version still reads.
    public var overdueTotal: Double?
    /// Due within the next 7 days, not overdue.
    public var dueSoonCount: Int?
    public var dueSoonTotal: Double?
    /// Bills paid since the start of this month.
    public var paidThisMonthCount: Int?
    public var paidThisMonthTotal: Double?
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
        /// The owner's colour in the app.
        public var ownerColor: OwnerColor?

        public init(id: UUID, sender: String, owner: String, amount: Double?, dueDate: Date?, ownerColor: OwnerColor? = nil) {
            self.id = id
            self.sender = sender
            self.owner = owner
            self.amount = amount
            self.dueDate = dueDate
            self.ownerColor = ownerColor
        }

        public func isOverdue(today: Date, calendar: Calendar = .current) -> Bool {
            (dueDate ?? .distantFuture) < calendar.startOfDay(for: today)
        }

        /// Days from today to the due date; negative when overdue.
        public func daysUntilDue(today: Date, calendar: Calendar = .current) -> Int? {
            guard let dueDate else { return nil }
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: today), to: calendar.startOfDay(for: dueDate)).day
        }

        /// "3 days overdue", "Due today", "Due tomorrow", "Due in 4 days", "Due 6 Dec", or "No due date".
        public func dueText(today: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
            guard let days = daysUntilDue(today: today, calendar: calendar), let dueDate else {
                return String(localized: "No due date", bundle: .module)
            }
            switch days {
            case ..<(-1): return String(localized: "\(-days) days overdue", bundle: .module)
            case -1: return String(localized: "1 day overdue", bundle: .module)
            case 0: return String(localized: "Due today", bundle: .module)
            case 1: return String(localized: "Due tomorrow", bundle: .module)
            case 2...7: return String(localized: "Due in \(days) days", bundle: .module)
            default:
                var style = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(locale)
                style.calendar = calendar
                style.timeZone = calendar.timeZone
                return String(localized: "Due \(dueDate.formatted(style))", bundle: .module)
            }
        }
    }

    public init(updatedAt: Date, hidesDetails: Bool, reviewCount: Int, openBillCount: Int, openBillTotal: Double?,
                overdueCount: Int, overdueTotal: Double? = nil, dueSoonCount: Int? = nil, dueSoonTotal: Double? = nil,
                paidThisMonthCount: Int? = nil, paidThisMonthTotal: Double? = nil,
                expenseCount: Int, expenseTotal: Double?, bills: [Bill]) {
        self.updatedAt = updatedAt
        self.hidesDetails = hidesDetails
        self.reviewCount = reviewCount
        self.openBillCount = openBillCount
        self.openBillTotal = openBillTotal
        self.overdueCount = overdueCount
        self.overdueTotal = overdueTotal
        self.dueSoonCount = dueSoonCount
        self.dueSoonTotal = dueSoonTotal
        self.paidThisMonthCount = paidThisMonthCount
        self.paidThisMonthTotal = paidThisMonthTotal
        self.expenseCount = expenseCount
        self.expenseTotal = expenseTotal
        self.bills = bills
    }

    /// Builds the summary from the open bills and the expenses still to claim.
    /// - Parameter paidThisMonth: Amounts of bills paid since the start of this month.
    public static func make(openBills: [Bill], expenseAmounts: [Double?], reviewCount: Int, hidesDetails: Bool,
                            paidThisMonth: [Double?] = [], now: Date = .now, calendar: Calendar = .current) -> WidgetSnapshot {
        let sorted = openBills.sorted { ($0.dueDate ?? .distantFuture, $0.sender) < ($1.dueDate ?? .distantFuture, $1.sender) }
        let overdue = openBills.filter { $0.isOverdue(today: now, calendar: calendar) }
        let dueSoon = openBills.filter { (0...7).contains($0.daysUntilDue(today: now, calendar: calendar) ?? -1) }
        return WidgetSnapshot(
            updatedAt: now,
            hidesDetails: hidesDetails,
            reviewCount: reviewCount,
            openBillCount: openBills.count,
            openBillTotal: hidesDetails ? nil : ShortcutAnswers.total(openBills.map(\.amount)),
            overdueCount: overdue.count,
            overdueTotal: hidesDetails ? nil : ShortcutAnswers.total(overdue.map(\.amount)),
            dueSoonCount: dueSoon.count,
            dueSoonTotal: hidesDetails ? nil : ShortcutAnswers.total(dueSoon.map(\.amount)),
            paidThisMonthCount: paidThisMonth.count,
            paidThisMonthTotal: hidesDetails ? nil : ShortcutAnswers.total(paidThisMonth),
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
            Bill(id: UUID(), sender: "Voorbeeld Energie", owner: "Private", amount: 142.37, dueDate: now.addingTimeInterval(-3 * day), ownerColor: .orange),
            Bill(id: UUID(), sender: "Schildersbedrijf Voorbeeld", owner: "Company1", amount: 853.66, dueDate: now.addingTimeInterval(4 * day), ownerColor: .blue),
            Bill(id: UUID(), sender: "Example Cloud", owner: "Company1", amount: 29, dueDate: now.addingTimeInterval(12 * day), ownerColor: .blue),
            Bill(id: UUID(), sender: "Drukkerij Test", owner: "Company2", amount: 96.80, dueDate: now.addingTimeInterval(20 * day), ownerColor: .teal),
        ], expenseAmounts: [12.10], reviewCount: 2, hidesDetails: false, paidThisMonth: [64.50, 230], now: now)
    }
}

/// Links from widgets into the app.
public enum WidgetLink {
    public static let toPay = URL(string: "papertrail://topay")!
    public static let review = URL(string: "papertrail://review")!
    public static let expenses = URL(string: "papertrail://expenses")!

    public static func bill(_ id: UUID) -> URL { URL(string: "papertrail://bill/\(id.uuidString)")! }
}
