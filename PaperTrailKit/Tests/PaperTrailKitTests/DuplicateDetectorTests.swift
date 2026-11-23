import Foundation
import Testing
@testable import PaperTrailKit

@Suite("DuplicateDetector")
struct DuplicateDetectorTests {
    static let calendar = TestSupport.calendar

    static func date(_ day: Int, month: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    static func facts(hash: String? = nil, sender: String = "Voorbeeld Energie", amount: Double? = nil, reference: String? = nil,
                      documentDate: Date? = nil, received: Date = date(5)) -> DuplicateFacts {
        DuplicateFacts(contentHash: hash, sender: sender, amount: amount, reference: reference, documentDate: documentDate, receivedDate: received)
    }

    static func reasons(_ candidate: DuplicateFacts, _ existing: [DuplicateFacts]) -> [DuplicateMatch.Reason] {
        DuplicateDetector.matches(for: candidate, in: existing, calendar: calendar).map(\.reason)
    }

    @Test func sameFileMatchesWhateverTheDetails() {
        #expect(Self.reasons(Self.facts(hash: "abc", sender: "A"), [Self.facts(hash: "abc", sender: "B")]) == [.sameFile])
    }

    @Test func sameInvoiceNumberFromSameSender() {
        let existing = Self.facts(sender: "Voorbeeld Energie B.V.", reference: "VE-2026-031455")
        #expect(Self.reasons(Self.facts(reference: "ve 2026 031455"), [existing]) == [.sameReference])
    }

    @Test func sameReferenceFromAnotherSenderIsNotADuplicate() {
        #expect(Self.reasons(Self.facts(reference: "2026-0112"), [Self.facts(sender: "Testkwast", reference: "2026-0112")]).isEmpty)
    }

    @Test func shortReferencesAreIgnored() {
        #expect(Self.reasons(Self.facts(reference: "12"), [Self.facts(reference: "12")]).isEmpty)
    }

    @Test func sameAmountAndDocumentDate() {
        let existing = Self.facts(amount: 142.37, documentDate: Self.date(3))
        #expect(Self.reasons(Self.facts(amount: 142.37, documentDate: Self.date(3)), [existing]) == [.sameSenderAmountAndDate])
    }

    @Test func monthlyBillWithSameAmountIsNotADuplicate() {
        let february = Self.facts(amount: 45.99, documentDate: Self.date(20, month: 2), received: Self.date(21, month: 2))
        let march = Self.facts(amount: 45.99, documentDate: Self.date(20), received: Self.date(21))
        #expect(Self.reasons(march, [february]).isEmpty)
    }

    @Test func withoutDocumentDatesReceivedDatesMustBeClose() {
        let existing = Self.facts(amount: 23.85, received: Self.date(1))
        #expect(Self.reasons(Self.facts(amount: 23.85, received: Self.date(6)), [existing]) == [.sameSenderAmountAndDate])
        #expect(Self.reasons(Self.facts(amount: 23.85, received: Self.date(20)), [existing]).isEmpty)
    }

    @Test func strongestReasonFirst() {
        let byAmount = Self.facts(amount: 10, documentDate: Self.date(3))
        let byFile = Self.facts(hash: "abc", sender: "Other")
        let result = Self.reasons(Self.facts(hash: "abc", amount: 10, documentDate: Self.date(3)), [byAmount, byFile])
        #expect(result == [.sameFile, .sameSenderAmountAndDate])
    }
}
