import Foundation

/// What Siri and Shortcuts say for Paper Trail's actions. Plain values in, a sentence out,
/// so the wording can be tested without the app.
public enum ShortcutAnswers {
    public struct Bill: Sendable, Equatable {
        public var sender: String
        public var amount: Double?
        public var dueDate: Date?

        public init(sender: String, amount: Double?, dueDate: Date?) {
            self.sender = sender
            self.amount = amount
            self.dueDate = dueDate
        }
    }

    /// Total in cents-exact euros.
    public static func total(_ amounts: [Double?]) -> Double {
        Double(amounts.compactMap { $0 }.map { Int(($0 * 100).rounded()) }.reduce(0, +)) / 100
    }

    /// "2 bills to pay, € 996,03 in total. Overdue: Voorbeeld Energie, € 142,37."
    public static func billsToPay(_ bills: [Bill], today: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        guard !bills.isEmpty else { return String(localized: "Nothing to pay. All bills are paid.", bundle: .module) }
        let total = BillReminderText.amount(total(bills.map(\.amount)), locale: locale)
        var text = bills.count == 1
            ? String(localized: "1 bill to pay, \(total).", bundle: .module)
            : String(localized: "\(bills.count) bills to pay, \(total) in total.", bundle: .module)
        let startOfToday = calendar.startOfDay(for: today)
        let overdue = bills.filter { ($0.dueDate ?? .distantFuture) < startOfToday }
        if !overdue.isEmpty {
            let list = overdue.map { describe($0, locale: locale) }.formatted(.list(type: .and).locale(locale))
            text += " " + String(localized: "Overdue: \(list).", bundle: .module)
        } else if let next = bills.filter({ $0.dueDate != nil }).min(by: { $0.dueDate! < $1.dueDate! }), let due = next.dueDate {
            let day = due.formatted(.dateTime.day().month(.wide).locale(locale))
            text += " " + String(localized: "Next due: \(describe(next, locale: locale)) on \(day).", bundle: .module)
        }
        return text
    }

    /// Open expenses per company: "Company1: 2 expenses, € 30,00."
    public static func expensesToClaim(_ perCompany: [(company: String, amounts: [Double?])], locale: Locale = .current) -> String {
        let open = perCompany.filter { !$0.amounts.isEmpty }
        guard !open.isEmpty else { return String(localized: "No expenses to claim.", bundle: .module) }
        return open.map { entry in
            let total = BillReminderText.amount(total(entry.amounts), locale: locale)
            return entry.amounts.count == 1
                ? String(localized: "\(entry.company): 1 expense, \(total).", bundle: .module)
                : String(localized: "\(entry.company): \(entry.amounts.count) expenses, \(total).", bundle: .module)
        }.joined(separator: " ")
    }

    static func describe(_ bill: Bill, locale: Locale) -> String {
        guard let amount = bill.amount else { return bill.sender }
        return "\(bill.sender), \(BillReminderText.amount(amount, locale: locale))"
    }
}
