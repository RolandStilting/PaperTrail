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

    @Test func tillReceiptSayingTeBetalenIsStillReceipt() {
        let text = "TOTAAL TE BETALEN 49,02\nBetaald met Maestro\nFactuur op aanvraag\nContactloos\nBedankt voor uw aankoop!"
        #expect(Self.checked(text).category == "Receipts")
    }

    @Test func receiptDescriptionDoesNotSayInvoice() {
        #expect(ExtractionChecks.receiptDescription("Factuur voor verf en tape") == "Kassabon voor verf en tape")
        #expect(ExtractionChecks.receiptDescription("Invoice hotel Berlin") == "Receipt hotel Berlin")
        #expect(ExtractionChecks.receiptDescription("Boodschappen") == "Boodschappen")
    }

    @Test func paymentRequestIsNotReceipt() {
        #expect(Self.checked("Factuurnummer 12\nTe betalen € 10,00 via PIN of overmaken").category == "Invoices")
        #expect(Self.checked("Invoice number 7\nCard payment received, thank you").category == "Invoices")
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

@Suite("ExtractionChecks values")
struct ExtractionValueChecksTests {
    static let categories = ArchiveSettings.defaults.categories.map(\.name)

    static func bill(sender: String = "Voorbeeld Energie", documentDate: String = "", unpaid: Bool = true,
                     amount: Double = 0, dueDate: String = "", iban: String = "", reference: String = "") -> ModelExtraction {
        ModelExtraction(sender: sender, documentDate: documentDate, category: "Invoices", description: "Factuur",
                        isUnpaidBill: unpaid, amount: amount, dueDate: dueDate, iban: iban, reference: reference)
    }

    static func check(_ extraction: ModelExtraction, _ text: String) -> ModelExtraction {
        ExtractionChecks.apply(extraction, text: text, categories: categories)
    }

    @Test func findsDatesInDutchAndEnglish() {
        let dates = TextDates.all(in: "Datum 3 maart 2026, vóór 17-03-2026, on March 5, 2026 or 2026-04-01 and 09.01.2026, not 31-02-2026")
            .map(\.date)
        #expect(dates == ["2026-03-03", "2026-03-17", "2026-03-05", "2026-04-01", "2026-01-09"])
    }

    @Test func dropsInventedDueDate() {
        let result = Self.check(Self.bill(dueDate: "2026-01-01"), "Factuur, totaal € 10,00")
        #expect(result.dueDate == "")
    }

    @Test func prefersNewDeadlineInReminder() {
        let text = "De vervaldatum was 10-02-2026. Wilt u het bedrag uiterlijk 27 februari 2026 overmaken?"
        #expect(Self.check(Self.bill(dueDate: "2026-02-10"), text).dueDate == "2026-02-27")
    }

    @Test func directDebitIsNotUnpaid() {
        let text = "Wij schrijven het bedrag van € 98,10 op 28-03-2026 automatisch af van uw rekening NL00TEST0555666777."
        let result = Self.check(Self.bill(amount: 98.10, dueDate: "2026-03-28", iban: "NL00TEST0555666777"), text)
        #expect(!result.isUnpaidBill)
        #expect(result.dueDate == "")
        #expect(result.iban == "")
        #expect(result.amount == 98.10)
    }

    @Test func keepsIbanWrittenWithSpaces() {
        let text = "Totaal te betalen € 812,40 uiterlijk op 31-03-2026 op NL00 TEST 0987 6543 21."
        let result = Self.check(Self.bill(amount: 812.40, iban: "NL00 TEST 0987 6543 21"), text)
        #expect(result.iban == "NL00TEST0987654321")
        #expect(result.dueDate == "2026-03-31")
    }

    @Test func dropsIbanNotInText() {
        #expect(Self.check(Self.bill(iban: "NL00TEST0123456789"), "Te betalen € 5,00").iban == "")
    }

    @Test func documentDateFallsBackToLabel() {
        let text = "Invoice date: 1 March 2026\nTotal EUR 29.00"
        #expect(Self.check(Self.bill(documentDate: "2026-01-01", unpaid: false), text).documentDate == "2026-03-01")
    }

    @Test func amountMustAppearInText() {
        #expect(ExtractionChecks.amountAppears(2318.40, in: "totaal € 2.318,40"))
        #expect(ExtractionChecks.amountAppears(29, in: "total eur 29.00"))
        #expect(ExtractionChecks.amountAppears(385, in: "eigen risico: € 385"))
        #expect(!ExtractionChecks.amountAppears(18.40, in: "totaal € 2.318,40"))
        #expect(Self.check(Self.bill(amount: 99.99), "Totaal € 10,00").amount == 0)
    }

    @Test func betalingskenmerkBeatsAssessmentNumber() {
        let text = "Aanslagnummer: 2026.0044.7781\nBetalingskenmerk: 5123 4567 8901 2345"
        #expect(Self.check(Self.bill(reference: "2026.0044.7781"), text).reference == "5123456789012345")
    }

    @Test func senderLosesLegalForm() {
        #expect(Self.check(Self.bill(sender: "Fictieve Bank N.V."), "Brief").sender == "Fictieve Bank")
    }
}

@Test func labelsMatchWholeWordsOnly() {
    #expect(TextDates.date(after: ["voor"], in: "Voorwaarden 1 april 2026") == nil)
    #expect(TextDates.date(after: ["voor"], in: "betalen voor 1 april 2026") == "2026-04-01")
}
