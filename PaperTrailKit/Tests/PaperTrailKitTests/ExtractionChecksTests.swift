import Foundation
import Testing
@testable import PaperTrailKit

@Suite("ExtractionChecks")
struct ExtractionChecksTests {
    static let categories = ArchiveSettings.defaults.categories.map(\.name)

    static func extraction(category: String = "Invoices") -> ModelExtraction {
        ModelExtraction(sender: "Testmarkt", documentDate: "", category: category, description: "Boodschappen",
                        isUnpaidBill: false, amount: 0, dueDate: "", iban: "", reference: "")
    }

    static func checked(_ text: String, category: String = "Invoices") -> ModelExtraction {
        ExtractionChecks.apply(extraction(category: category), text: text, categories: categories)
    }

    @Test func tillReceiptGoesToReceipts() {
        #expect(Self.checked("TESTMARKT\nTOTAAL 23,85\nPIN 23,85\nKassa 3 Bon 0041").category == "Receipts")
    }

    @Test func hotelReceiptGoesToReceipts() {
        #expect(Self.checked("Hotel Sample\nRECEIPT\nTotal EUR 312.00\nPaid: Mastercard").category == "Receipts")
    }

    @Test func invoiceMentioningPaymentStaysInvoice() {
        #expect(Self.checked("INVOICE\nInvoice number: INV-1\nPaid by Visa. Thank you!").category == "Invoices")
        #expect(Self.checked("FACTUUR\nTotaal te betalen € 10,00\nU kunt ook betalen met PIN").category == "Invoices")
    }

    @Test func wordsInsideOtherWordsDoNotCount() {
        // "pinpas" and "bonus" must not count as "pin" and "bon".
        #expect(Self.checked("Uw nieuwe pinpas en bonus", category: "Bank").category == "Bank")
    }

    @Test func receiptsCategoryMissingFromSettings() {
        let result = ExtractionChecks.apply(Self.extraction(), text: "Kassabon PIN", categories: ["Invoices", "Other"])
        #expect(result.category == "Invoices")
    }

    @Test func categorySnapsToSettingsSpelling() {
        #expect(Self.checked("Brief", category: "letters").category == "Letters")
        #expect(Self.checked("Brief", category: "Groceries").category == "")
    }

    @Test func hintsCoverDefaultsAndSkipCustomCategories() {
        let lines = CategoryHints.describe(["Receipts", "Travel"]).split(separator: "\n")
        #expect(lines[0].hasPrefix("- Receipts: proof of a payment"))
        #expect(lines[1] == "- Travel")
    }
}
