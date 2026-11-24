import Foundation
import Testing
@testable import PaperTrailKit

/// Synthetic senders and amounts.
@Suite("ShortcutAnswers")
struct ShortcutAnswersTests {
    let locale = Locale(identifier: "en_NL")
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()
    func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day))! }

    @Test func billsWithOverdue() {
        let text = ShortcutAnswers.billsToPay([
            .init(sender: "Voorbeeld Energie", amount: 142.37, dueDate: date(21)),
            .init(sender: "Schildersbedrijf Voorbeeld", amount: 853.66, dueDate: date(28)),
        ], today: date(24), locale: locale, calendar: calendar)
        #expect(text.hasPrefix("2 bills to pay, "))
        #expect(text.contains("996,03"))
        #expect(text.contains("Overdue: Voorbeeld Energie, "))
        #expect(!text.contains("Schildersbedrijf"))
    }

    @Test func billsWithNextDue() {
        let text = ShortcutAnswers.billsToPay([
            .init(sender: "Voorbeeld Energie", amount: 142.37, dueDate: date(30)),
            .init(sender: "Example Cloud", amount: nil, dueDate: nil),
        ], today: date(24), locale: locale, calendar: calendar)
        #expect(text.contains("Next due: Voorbeeld Energie, "))
        #expect(text.contains("30 November"))
    }

    @Test func nothingToPayOrClaim() {
        #expect(ShortcutAnswers.billsToPay([], today: date(24), locale: locale) == "Nothing to pay. All bills are paid.")
        #expect(ShortcutAnswers.expensesToClaim([("Company1", [])], locale: locale) == "No expenses to claim.")
    }

    @Test func expensesPerCompany() {
        let text = ShortcutAnswers.expensesToClaim([("Company1", [12.10, 17.90]), ("Company2", [5])], locale: locale)
        #expect(text.hasPrefix("Company1: 2 expenses, "))
        #expect(text.contains("30,00"))
        #expect(text.contains("Company2: 1 expense, "))
    }
}
