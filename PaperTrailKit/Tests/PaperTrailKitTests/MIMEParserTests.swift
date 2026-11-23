import Foundation
import Testing
@testable import PaperTrailKit

/// All emails here are synthetic.
@Suite("MIMEParser")
struct MIMEParserTests {
    static let pdfBytes = Data("%PDF-1.7 synthetic attachment \u{00}\u{FF} bytes".utf8)

    static func crlf(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    static let withAttachment = crlf("""
    From: =?utf-8?Q?Voorbeeld_Energie_B.V.?= <factuur@voorbeeld-energie.example>
    To: archief@example.com
    Subject: =?utf-8?B?RmFjdHV1ciBtYWFydCDigqwgMTQyLDM3?=
    Date: Tue, 3 Mar 2026 09:15:00 +0100
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="outer"

    --outer
    Content-Type: multipart/alternative; boundary=inner

    --inner
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Beste klant, in de bijlage vindt u uw factuur van =E2=82=AC 142,37.=
     Met vriendelijke groet
    --inner
    Content-Type: text/html; charset=utf-8

    <p>Beste klant</p>
    --inner--
    --outer
    Content-Type: image/png
    Content-Disposition: inline; filename="logo.png"
    Content-Transfer-Encoding: base64

    iVBORw0KGgo=
    --outer
    Content-Type: application/octet-stream; name="Factuur VE-2026-031455.pdf"
    Content-Disposition: attachment; filename*=utf-8''Factuur%20VE-2026-031455.pdf
    Content-Transfer-Encoding: base64

    \(pdfBytes.base64EncodedString(options: .lineLength76Characters).replacingOccurrences(of: "\r\n", with: "\n"))
    --outer--
    """)

    @Test func readsHeaders() throws {
        let message = MIMEParser.parse(Self.withAttachment)
        #expect(message.from == "Voorbeeld Energie B.V. <factuur@voorbeeld-energie.example>")
        #expect(message.subject == "Factuur maart € 142,37")
        let date = try #require(message.date)
        #expect(date == ISO8601DateFormatter().date(from: "2026-03-03T08:15:00Z"))
    }

    @Test func findsPdfAttachmentAndSkipsInlineLogo() {
        let documents = EmailIntake.documents(in: MIMEParser.parse(Self.withAttachment))
        #expect(documents == [.pdf(name: "Factuur VE-2026-031455.pdf", data: Self.pdfBytes)])
    }

    @Test func decodesQuotedPrintableText() {
        let message = MIMEParser.parse(Self.withAttachment)
        let text = message.leaves.first { $0.contentType == "text/plain" }?.text
        #expect(text == "Beste klant, in de bijlage vindt u uw factuur van € 142,37. Met vriendelijke groet")
    }

    @Test func htmlOnlyEmailBecomesHtmlDocument() {
        let raw = Self.crlf("""
        From: Webshop Voorbeeld <noreply@webshop.example>
        Subject: Je bestelling 1234
        Content-Type: text/html; charset=iso-8859-1
        Content-Transfer-Encoding: quoted-printable

        <h1>Bedankt voor je bestelling</h1><p>Totaal: =80 19,95 caf=E9</p>
        """)
        let documents = EmailIntake.documents(in: MIMEParser.parse(raw))
        #expect(documents == [.html("<h1>Bedankt voor je bestelling</h1><p>Totaal: \u{80} 19,95 café</p>")])
    }

    @Test func plainTextEmailBecomesTextDocument() {
        let raw = Self.crlf("From: a@example.com\nSubject: Bon\n\nBedrag 12,50\n")
        let message = MIMEParser.parse(raw)
        #expect(EmailIntake.documents(in: message) == [.text("Bedrag 12,50")])
        #expect(EmailIntake.label(for: message) == "Bon")
    }

    @Test func attachedPhotoIsKept() {
        let raw = Self.crlf("""
        From: a@example.com
        Subject: Bonnetje
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: text/plain

        Zie foto
        --b
        Content-Type: image/jpeg
        Content-Disposition: attachment; filename="IMG_0001.jpg"
        Content-Transfer-Encoding: base64

        /9j/4AAQ
        --b--
        """)
        let documents = EmailIntake.documents(in: MIMEParser.parse(raw))
        #expect(documents == [.image(name: "IMG_0001.jpg", data: Data(base64Encoded: "/9j/4AAQ")!)])
    }
}
