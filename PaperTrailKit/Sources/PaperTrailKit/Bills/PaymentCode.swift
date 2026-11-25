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
        "ideal", "tikkie", "betaal", "betalen", "pay", "mollie", "adyen", "buckaroo", "multisafepay",
        "rabo", "abnamro", "asnbank", "ing.nl", "bunq", "knab", "sepa", "wero", "factuur", "invoice",
    ]

    /// Pages about the sender rather than about paying: never a payment link, even when the
    /// address has a payment word ("/betaalvoorwaarden", "/factuur-uitleg").
    static let informationWords = [
        "voorwaarden", "terms", "conditions", "privacy", "cookie", "disclaimer", "faq", "veelgestelde",
        "uitleg", "explain", "contact", "klantenservice", "help", "support", "over-ons", "about",
    ]

    /// When these rules last changed: codes found earlier (or none) are searched for again once.
    public static let rulesChangedAt = Date(timeIntervalSince1970: 1_795_600_000)  // 2026-11-25

    /// Whether a bill should be searched (again): never searched, or searched before the rules
    /// changed without finding a QR code.
    public static func needsSearch(checkedAt: Date?, found: PaymentCode?) -> Bool {
        guard let checkedAt else { return true }
        return checkedAt < rulesChangedAt && found?.source != .qrCode
    }

    /// Picks the payment code from what was found on a document: a QR code first (one that
    /// links to a payment page, else any web link: on a bill a QR code is almost always for
    /// paying), then a link to a payment page.
    /// - Parameters:
    ///   - qrPayloads: Contents of the QR codes on the pages.
    ///   - links: Link annotations in the PDF.
    ///   - text: The document's text, searched for payment links.
    public static func find(qrPayloads: [String], links: [URL], text: String) -> PaymentCode? {
        for payload in qrPayloads {
            if let code = fromQRCode(payload) { return code }
        }
        for payload in qrPayloads {
            let payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if !payload.hasPrefix("BCD"), webURL(payload) != nil { return PaymentCode(source: .qrCode, payload: payload) }
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

    /// An https link whose host or path suggests paying, and isn't an information page.
    public static func isPaymentLink(_ text: String) -> Bool {
        guard let url = webURL(text), let host = url.host()?.lowercased() else { return false }
        let path = url.path().lowercased()
        guard !informationWords.contains(where: path.contains) else { return false }
        let checked = host + path
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
