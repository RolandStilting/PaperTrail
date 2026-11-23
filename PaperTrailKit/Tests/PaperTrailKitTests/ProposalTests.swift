import Foundation
import Testing
@testable import PaperTrailKit

@Suite("Proposal")
struct ProposalTests {
    static let calendar = TestSupport.calendar

    static func extraction() -> ModelExtraction {
        ModelExtraction(sender: "Voorbeeld Energie", documentDate: "2026-03-03", category: "Invoices",
                        description: "Energierekening februari 2026 voor elektriciteit en gas", isUnpaidBill: true,
                        amount: 142.371, dueDate: "2026-03-17", iban: "NL00TEST0123456789", reference: " VE-2026-031455 ")
    }

    @Test func convertsCheckedModelOutput() {
        let proposal = Proposal(Self.extraction(), calendar: Self.calendar)
        #expect(proposal.sender == "Voorbeeld Energie")
        #expect(proposal.category == "Invoices")
        #expect(proposal.description == "Energierekening februari 2026 voor elektriciteit en")
        #expect(proposal.documentDate.map { FileNamer(calendar: Self.calendar).dateString($0) } == "2026-03-03")
        #expect(proposal.bill.dueDate.map { FileNamer(calendar: Self.calendar).dateString($0) } == "2026-03-17")
        #expect(proposal.bill.amount == 142.37)
        #expect(proposal.bill.reference == "VE-2026-031455")
        #expect(proposal.bill.isUnpaid)
    }

    @Test func emptyValuesBecomeNoSuggestion() {
        var extraction = Self.extraction()
        (extraction.documentDate, extraction.dueDate, extraction.amount) = ("", "2026-02-30", 0)
        let proposal = Proposal(extraction, calendar: Self.calendar)
        #expect(proposal.documentDate == nil)
        #expect(proposal.bill.dueDate == nil)
        #expect(proposal.bill.amount == nil)
    }

    @Test func recordStoresBillDetails() {
        let bill = BillDetails(isUnpaid: true, amount: 45.99, iban: "NL00TEST0111222333", reference: "")
        let record = DocumentRecord(relativePath: "a.pdf", ownerName: "Private", categoryName: "Invoices", sender: "Praatnet",
                                    documentDescription: "Herinnering", receivedDate: .now, source: .scan, bill: bill)
        #expect(record.isUnpaidBill)
        #expect(record.amount == 45.99)
        #expect(record.iban == "NL00TEST0111222333")
        #expect(record.paymentReference == nil)
    }
}

@Suite("ModelAvailability")
struct ModelAvailabilityTests {
    @Test func everyReasonSaysWhatToDo() {
        let reasons: [ModelUnavailableReason] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .other("test")]
        let messages = reasons.map(\.message)
        #expect(Set(messages).count == reasons.count)
        #expect(messages[1].contains("Settings"))
        #expect(messages[3].contains("test"))
    }
}
