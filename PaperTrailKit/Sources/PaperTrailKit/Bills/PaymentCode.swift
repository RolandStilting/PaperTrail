import Foundation

/// A way to pay that the sender put on the document itself: a QR code (e.g. iDEAL or Tikkie)
/// or a "pay now" link. Banking apps that refuse a generic EPC QR code accept these, because
/// the payee's own payment provider made them.
public struct PaymentCode: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// A QR code printed on the document; shown again so a phone can scan it.
        case qrCode
        /// A link in the PDF or its text.
        case link
    }

    public var source: Source
    /// The QR code's content, or the link.
    public var payload: String

    public init(source: Source, payload: String) {
        self.source = source
        self.payload = payload
    }

    /// The payment page, when the payload is a web link.
    public var url: URL? { PaymentCode.webURL(payload) }

    /// Host shown on the button, so the user sees where the link goes.
    public var host: String? { url?.host() }

    // MARK: Stored form

    /// JSON for `DocumentRecord.paymentCodeText`; empty when none was found.
    public var encoded: String {
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? ""
    }

    public static func decode(_ text: String) -> PaymentCode? {
        guard !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(PaymentCode.self, from: Data(text.utf8))
    }

    // MARK: Finding codes

    /// Words in a link's host or path that mark it as a payment page.
    static let paymentWords = [
        "ideal", "tikkie", "betaal", "pay", "mollie", "adyen", "buckaroo", "multisafepay",
        "rabo", "abnamro", "asnbank", "ing.nl", "bunq", "knab", "sepa", "wero", "factuur", "invoice",
    ]

    /// Picks the payment code from what was found on a document: a QR code first, then a link.
    /// - Parameters:
    ///   - qrPayloads: Contents of the QR codes on the pages.
    ///   - links: Link annotations in the PDF.
    ///   - text: The document's text, searched for payment links.
    public static func find(qrPayloads: [String], links: [URL], text: String) -> PaymentCode? {
        for payload in qrPayloads {
            if let code = fromQRCode(payload) { return code }
        }
        let candidates = links.map(\.absoluteString) + linksInText(text)
        for link in candidates where isPaymentLink(link) {
            return PaymentCode(source: .link, payload: link)
        }
        return nil
    }

    /// A QR code worth showing: a payment page link. An EPC code is skipped (Paper Trail makes
    /// its own), and so are other contents such as plain text or a website without payment words.
    public static func fromQRCode(_ payload: String) -> PaymentCode? {
        let payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.hasPrefix("BCD"), isPaymentLink(payload) else { return nil }
        return PaymentCode(source: .qrCode, payload: payload)
    }

    /// An https link whose host or path suggests paying.
    public static func isPaymentLink(_ text: String) -> Bool {
        guard let url = webURL(text), let host = url.host()?.lowercased() else { return false }
        let checked = host + url.path().lowercased()
        return paymentWords.contains { checked.contains($0) }
    }

    static func webURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return url
    }

    static func linksInText(_ text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { $0.url?.absoluteString }
    }
}
