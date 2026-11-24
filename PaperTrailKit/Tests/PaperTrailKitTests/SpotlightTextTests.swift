import Foundation
import Testing
@testable import PaperTrailKit

@Suite("SpotlightText")
struct SpotlightTextTests {
    @Test func title() {
        #expect(SpotlightText.title(sender: "Voorbeeld Energie", description: "Energierekening oktober") == "Voorbeeld Energie – Energierekening oktober")
        #expect(SpotlightText.title(sender: "Testmarkt", description: " ") == "Testmarkt")
    }

    @Test func summary() {
        let calendar = TestSupport.calendar
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 12))!
        let text = SpotlightText.summary(received: date, owner: "Private", category: "Invoices", amount: 42.5,
                                         locale: Locale(identifier: "en_GB"), calendar: calendar)
        #expect(text.hasPrefix("3 Mar 2026 · Private › Invoices · "))
        #expect(text.contains("42.50"))
        #expect(!SpotlightText.summary(received: date, owner: "Private", category: "Letters", amount: nil, calendar: calendar).contains("·  "))
    }

    @Test func keywordsSkipEmpty() {
        #expect(SpotlightText.keywords(sender: "Testmarkt", owner: "Private", category: "Receipts", reference: nil) == ["Testmarkt", "Private", "Receipts"])
    }
}
