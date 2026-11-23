import Foundation
import Testing
@testable import PaperTrailKit

/// All documents are synthetic.
@Suite("VATExtractor")
struct VATExtractorTests {
    static func fixture(_ folder: String, _ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(folder)/\(name)", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func supermarketLineWithBase() throws {
        let info = VATExtractor.extract(from: try Self.fixture("Extraction", "nl_supermarket_receipt"), total: 23.85)
        #expect(info.lines == [VATLine(rate: 9, base: 21.88, amount: 1.97)])
        #expect(!info.isForeign && !info.isReverseCharge)
    }

    @Test func twoRatesOnOneReceipt() throws {
        let info = VATExtractor.extract(from: try Self.fixture("VAT", "nl_two_rates_receipt"), total: 17.39)
        #expect(info.lines == [VATLine(rate: 9, base: 4.49, amount: 0.40), VATLine(rate: 21, base: 10.33, amount: 2.17)])
        #expect(info.total == 2.57)
    }

    @Test func singleAmountUsesTheDocumentTotalForTheBase() throws {
        let info = VATExtractor.extract(from: try Self.fixture("Extraction", "nl_invoice_payment_term"), total: 853.66)
        #expect(info.lines == [VATLine(rate: 21, base: 705.50, amount: 148.16)])
    }

    @Test func englishInvoice() throws {
        let info = VATExtractor.extract(from: try Self.fixture("Extraction", "en_software_invoice"), total: 29)
        #expect(info.lines == [VATLine(rate: 21, base: 23.97, amount: 5.03)])
    }

    @Test func germanVATIsForeign() throws {
        let info = VATExtractor.extract(from: try Self.fixture("VAT", "de_hotel_receipt"), total: 204)
        #expect(info.isForeign)
        #expect(info.lines.map(\.rate) == [7, 19])
        #expect(info.total == 15.61)
    }

    @Test func reverseCharge() throws {
        let info = VATExtractor.extract(from: try Self.fixture("VAT", "eu_reverse_charge_invoice"), total: 600)
        #expect(info.isReverseCharge)
        #expect(info.lines == [VATLine(rate: 0, base: 600, amount: 0)])
    }

    @Test func inclusiveVATSentence() throws {
        let info = VATExtractor.extract(from: try Self.fixture("VAT", "nl_restaurant_receipt"), total: 11.20)
        #expect(info.lines == [VATLine(rate: 9, base: 10.28, amount: 0.92)])
    }

    @Test func noVATLineAndVATNumbersAreIgnored() throws {
        #expect(VATExtractor.extract(from: try Self.fixture("Extraction", "nl_energy_invoice"), total: 142.37).isEmpty)
        #expect(VATExtractor.extract(from: "KvK 00000000 | btw NL000000000B01\nTotaal 10,00").isEmpty)
    }

    @Test func encodesForTheIndex() {
        let info = VATInfo(lines: [VATLine(rate: 21, base: 100, amount: 21)], isForeign: false)
        #expect(VATInfo.decode(info.encoded) == info)
        #expect(VATInfo().encoded == "")
    }
}

@Suite("VATExtractor layouts")
struct VATExtractorLayoutTests {
    @Test func amountOnTheNextLine() throws {
        let info = VATExtractor.extract(from: try VATExtractorTests.fixture("VAT", "pdf_table_split_lines"), total: 34.98)
        #expect(info.lines == [VATLine(rate: 21, base: 28.91, amount: 6.07)])
    }

    @Test func itemLinesPlusTotalLineCountOnce() throws {
        let info = VATExtractor.extract(from: try VATExtractorTests.fixture("VAT", "item_and_total_vat_lines"), total: 11.98)
        #expect(info.lines.count == 1)
        #expect(info.total == 2.08)
    }

    @Test func twoItemsWithTheSameRateAreAddedUp() {
        let lines = [VATLine(rate: 21, base: 10, amount: 2.10), VATLine(rate: 21, base: 20, amount: 4.20)]
        #expect(VATExtractor.merged(lines) == [VATLine(rate: 21, base: 30, amount: 6.30)])
    }

    @Test func vatWithoutRateIsDerivedFromTheTotal() throws {
        let info = VATExtractor.extract(from: try VATExtractorTests.fixture("VAT", "vat_without_rate"), total: 12.10)
        #expect(info.lines == [VATLine(rate: 21, base: 10, amount: 2.10)])
    }

    @Test func inclusiveTotalIsNotReadAsVAT() throws {
        let info = VATExtractor.extract(from: try VATExtractorTests.fixture("VAT", "incl_vat_total_only"), total: 25)
        #expect(info.lines.isEmpty)
    }
}

@Suite("VATExtractor summary tables")
struct VATExtractorSummaryTableTests {
    @Test func headingsAboveARowOfNumbers() throws {
        let info = VATExtractor.extract(from: try VATExtractorTests.fixture("VAT", "summary_table_one_row"), total: 1028.50)
        #expect(info.lines == [VATLine(rate: 21, base: 850, amount: 178.50)])
        #expect(!info.isForeign)
    }

    @Test func cellsOnSeparateLines() throws {
        let info = VATExtractor.extract(from: try VATExtractorTests.fixture("VAT", "summary_table_split_cells"), total: 1357.62)
        #expect(info.lines == [VATLine(rate: 21, base: 1122, amount: 235.62)])
    }

    @Test func aPercentageUnderAHeadingNeedsAmountsThatCheckOut() {
        let text = "Btw-tarief\n21,00 %\nKorting 10,00"
        #expect(VATExtractor.extract(from: text, total: 100).isEmpty)
    }
}
