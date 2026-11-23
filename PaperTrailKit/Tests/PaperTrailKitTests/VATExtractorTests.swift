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
