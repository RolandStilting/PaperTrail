import Foundation
import Testing
@testable import PaperTrailKit

/// Synthetic links only; the hosts are invented or example domains.
@Suite("PaymentCode")
struct PaymentCodeTests {
    @Test func qrCodeWithPaymentLinkWins() {
        let code = PaymentCode.find(
            qrPayloads: ["https://www.example.com/over-ons", "https://pay.example-psp.test/ideal/AB12CD"],
            links: [URL(string: "https://betalen.example.test/factuur/1")!],
            text: "")
        #expect(code == PaymentCode(source: .qrCode, payload: "https://pay.example-psp.test/ideal/AB12CD"))
        #expect(code?.host == "pay.example-psp.test")
    }

    @Test func epcAndPlainQRCodesAreSkipped() {
        #expect(PaymentCode.fromQRCode("BCD\n002\n1\nSCT\n\nVoorbeeld BV\nNL00TEST0123456789\nEUR12.50") == nil)
        #expect(PaymentCode.fromQRCode("Klantnummer 12345") == nil)
        #expect(PaymentCode.fromQRCode("http://pay.example.test/insecure") == nil)
    }

    @Test func linkAnnotationThenTextLink() {
        let fromAnnotation = PaymentCode.find(qrPayloads: [], links: [URL(string: "https://www.example.test/privacy")!, URL(string: "https://example.test/betaal-nu?id=7")!], text: "")
        #expect(fromAnnotation == PaymentCode(source: .link, payload: "https://example.test/betaal-nu?id=7"))

        let fromText = PaymentCode.find(qrPayloads: [], links: [], text: "Betaal eenvoudig via https://tikkie.example.test/abc123 of maak het bedrag over.")
        #expect(fromText?.source == .link)
        #expect(fromText?.payload == "https://tikkie.example.test/abc123")
    }

    @Test func anyWebQRCodeBeatsALink() {
        let code = PaymentCode.find(qrPayloads: ["BCD\n002\n1\nSCT", "https://example.test/q/Ab12Cd"],
                                    links: [URL(string: "https://example.test/betalen")!], text: "")
        #expect(code == PaymentCode(source: .qrCode, payload: "https://example.test/q/Ab12Cd"))
        // Without a web QR code, the payment link is used.
        #expect(PaymentCode.find(qrPayloads: ["Klantnummer 12345"], links: [URL(string: "https://example.test/betalen")!], text: "")?.source == .link)
    }

    @Test func informationPagesAreNoPaymentLinks() {
        #expect(!PaymentCode.isPaymentLink("https://www.example.test/betaalvoorwaarden"))
        #expect(!PaymentCode.isPaymentLink("https://www.example.test/factuur-uitleg"))
        #expect(!PaymentCode.isPaymentLink("https://pay.example.test/terms"))
        #expect(PaymentCode.isPaymentLink("https://www.example.test/factuur/betalen?id=9"))
        let text = "Lees onze voorwaarden op https://www.example.test/betaalvoorwaarden."
        #expect(PaymentCode.find(qrPayloads: [], links: [], text: text) == nil)
    }

    @Test func searchedAgainOnceAfterTheRulesChanged() {
        let before = PaymentCode.rulesChangedAt.addingTimeInterval(-60), after = PaymentCode.rulesChangedAt.addingTimeInterval(60)
        let link = PaymentCode(source: .link, payload: "https://example.test/betalen")
        let qr = PaymentCode(source: .qrCode, payload: "https://example.test/q/1")
        #expect(PaymentCode.needsSearch(checkedAt: nil, found: nil))
        #expect(PaymentCode.needsSearch(checkedAt: before, found: link))
        #expect(PaymentCode.needsSearch(checkedAt: before, found: nil))
        #expect(!PaymentCode.needsSearch(checkedAt: before, found: qr))
        #expect(!PaymentCode.needsSearch(checkedAt: after, found: link))
    }

    @Test func nothingFound() {
        #expect(PaymentCode.find(qrPayloads: [], links: [], text: "Zie www.example.test voor onze voorwaarden.") == nil)
    }

    @Test func storedFormRoundTrips() {
        let code = PaymentCode(source: .link, payload: "https://pay.example.test/x")
        #expect(PaymentCode.decode(code.encoded) == code)
        #expect(PaymentCode.decode("") == nil)
    }
}
