import Foundation
import PaperTrailKit
import Testing
@testable import PaperTrail

@Suite("PaymentCodeScanner")
struct PaymentCodeScannerTests {
    /// A QR code like the ones on invoices (made here with an invented link) is read back.
    @Test func readsQRCode() async throws {
        let link = "https://pay.example-psp.test/ideal/AB12CD"
        let image = try #require(await MainActor.run { PaymentQRCode.render(link) })
        let payloads = try await PaymentCodeScanner.qrCodes(in: [image])
        #expect(payloads.contains(link))
        #expect(PaymentCode.find(qrPayloads: payloads, links: [], text: "")?.source == .qrCode)
    }
}
