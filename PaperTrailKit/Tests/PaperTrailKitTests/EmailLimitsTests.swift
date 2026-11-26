import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PaperTrailKit

/// Emails come from anyone: limits against crashes, floods and oversized content.
/// All messages are synthetic.
@Suite("Email limits")
struct EmailLimitsTests {
    static func crlf(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
    static let pdf = "%PDF-1.7 synthetic test document"

    static func message(parts: [String]) -> Data {
        var text = "From: a@example.test\nSubject: Test\nContent-Type: multipart/mixed; boundary=b\n\n"
        for part in parts { text += "--b\n\(part)\n" }
        return crlf(text + "--b--\n")
    }

    static func pdfPart(_ name: String, body: String = pdf) -> String {
        "Content-Type: application/pdf\nContent-Disposition: attachment; filename=\"\(name)\"\nContent-Transfer-Encoding: base64\n\n\(Data(body.utf8).base64EncodedString())"
    }

    @Test func deepNestingStopsAtTheLimit() {
        let depth = 5_000
        var text = ""
        for _ in 0..<depth { text += "Content-Type: message/rfc822\r\n\r\n" }
        text += "Content-Type: text/plain\r\n\r\nhallo\r\n"
        let message = MIMEParser.parse(Data(("Subject: Diep\r\n" + text).utf8))
        func depthOf(_ part: MIMEPart) -> Int { 1 + (part.children.map(depthOf).max() ?? 0) }
        #expect(depthOf(message.root) <= MIMEParser.maxDepth + 1)
        #expect(EmailIntake.documents(in: message).isEmpty)
    }

    @Test func partCountIsLimited() {
        let parts = (0..<(MIMEParser.maxParts + 200)).map { _ in "Content-Type: text/plain\n\nx" }
        let message = MIMEParser.parse(Self.message(parts: parts))
        #expect(message.leaves.count < MIMEParser.maxParts)
    }

    @Test func onlyRealPDFsAndAtMostTwenty() {
        var parts = [Self.pdfPart("echt.pdf"), Self.pdfPart("nep.pdf", body: "<html>no pdf here, just text pretending</html>")]
        parts += (1...30).map { Self.pdfPart("bijlage \($0).pdf") }
        let selection = EmailIntake.select(in: MIMEParser.parse(Self.message(parts: parts)))
        #expect(selection.documents.count == EmailIntake.maxDocuments)
        #expect(selection.documents.first == .pdf(name: "echt.pdf", data: Data(Self.pdf.utf8)))
        #expect(selection.skipped.count == 2)
        #expect(selection.skipped.contains { $0.contains("nep.pdf") })
        #expect(selection.skipped.contains { $0.contains("11") })  // 31 real PDFs, 20 taken
    }

    @Test func implausibleDateHeaderIsIgnored() {
        let now = Date(timeIntervalSince1970: 1_795_600_000)
        #expect(EmailIntake.receivedDate(header: now.addingTimeInterval(-3600), now: now) == now.addingTimeInterval(-3600))
        #expect(EmailIntake.receivedDate(header: now.addingTimeInterval(400 * 24 * 3600), now: now) == now)
        #expect(EmailIntake.receivedDate(header: now.addingTimeInterval(-400 * 24 * 3600), now: now) == now)
        #expect(EmailIntake.receivedDate(header: now.addingTimeInterval(600), now: now) == now)
        #expect(EmailIntake.receivedDate(header: nil, now: now) == now)
    }

    @Test func htmlCantReachOut() {
        let html = """
        <html><head><link rel="dns-prefetch" href="//tracker.example.test"><LINK rel=preconnect href="https://tracker.example.test">
        <base href="https://tracker.example.test/"><meta http-equiv="refresh" content="0;url=https://tracker.example.test">
        <meta http-equiv='Content-Security-Policy' content="default-src *"></head><body><p>Factuur</p></body></html>
        """
        let hardened = EmailHTML.hardened(html)
        #expect(!hardened.lowercased().contains("tracker"))
        #expect(!hardened.contains("default-src *"))
        #expect(hardened.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'"))
        #expect(hardened.contains("<p>Factuur</p>"))
    }

    @Test func imapRefusesControlCharacters() {
        #expect(IMAPSession.quoted("Paper\r\nTrail") == "\"PaperTrail\"")
        #expect(IMAPSession.hasControlCharacters("geheim\r\nA1 DELETE INBOX"))
        #expect(!IMAPSession.hasControlCharacters("abcd-efgh-ijkl-mnop"))
        var account = IMAPSessionTests.account
        account.folder = "Paper\tTrail"
        #expect(!account.validationErrors.isEmpty)
    }

    @Test func fileNamesStayUnder255Bytes() {
        let zalgo = String(repeating: "a\u{0301}\u{0302}\u{0303}\u{0304}", count: 60)
        let name = ReviewQueueNames.fileName(savedAt: Date(timeIntervalSince1970: 1_795_600_000), originalName: zalgo)
        #expect(name.utf8.count <= 200)
        #expect(FileNamer().cleanDescription(String(repeating: "Lang", count: 100)).utf8.count <= 150)
        #expect(FileNamer.prefix("€€€", maxBytes: 7) == "€€")
    }

    @Test func tallPagesAreRefused() throws {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: PDFPaginator.a4Height * 60)
        let context = try #require(CGContext(consumer: CGDataConsumer(data: output as CFMutableData)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        #expect(throws: PDFBuilderError.tooManyPages(PDFPaginator.maxPages)) { try PDFPaginator.paginate(output as Data) }
    }

    @Test func largeImagesAreScaledDownWhileDecoding() throws {
        let image = PDFBuilderTests.testImage(width: 6000, height: 300)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = PDFBuilder.images(fromImageData: data as Data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.width == PDFBuilder.maxImagePixels)
    }
}
