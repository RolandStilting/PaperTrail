#if os(macOS)
import CoreGraphics
import Foundation
import PaperTrailKit
import Testing
@testable import PaperTrail

@Suite("KeychainPasswordStore")
struct KeychainPasswordStoreTests {
    @Test func savesReplacesAndDeletes() throws {
        let store = KeychainPasswordStore(service: "PaperTrailTests.\(UUID().uuidString)")
        let account = "archief.voorbeeld"
        defer { try? store.delete(account: account) }
        #expect(try store.password(account: account) == nil)
        try store.save("abcd-efgh-ijkl-mnop", account: account)
        #expect(try store.password(account: account) == "abcd-efgh-ijkl-mnop")
        try store.save("qrst-uvwx-yzab-cdef", account: account)
        #expect(try store.password(account: account) == "qrst-uvwx-yzab-cdef")
        try store.delete(account: account)
        #expect(try store.password(account: account) == nil)
    }
}

@MainActor
@Suite("HTMLPDFRenderer")
struct HTMLPDFRendererTests {
    @Test func rendersLongEmailOnSeveralPages() async throws {
        let rows = (1...120).map { "<p>Regel \($0): Voorbeeldproduct · € 1,00</p>" }.joined()
        let html = "<html><body><h1>Bedankt voor je bestelling</h1>\(rows)<img src=\"https://tracker.example/pixel.gif\"></body></html>"
        let pdf = try await HTMLPDFRenderer().pdf(html: html)
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        #expect(document.numberOfPages >= 2)
        let box = try #require(document.page(at: 1)?.getBoxRect(.mediaBox))
        #expect(abs(box.width - HTMLPDFRenderer.width) < 1)
    }

    @Test func rendersPlainText() async throws {
        let pdf = try await HTMLPDFRenderer().pdf(text: "Bedrag <12,50>\nBedankt")
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 1)
    }
}
#endif
