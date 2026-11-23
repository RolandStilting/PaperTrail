import Foundation

/// Cheap keyword checks on document text, used to correct the model where its
/// judgement is unreliable. Everything here runs on the device.
public struct DocumentSignals: Sendable {
    /// Lowercased text with runs of whitespace collapsed to one space.
    public let text: String
    /// Lowercased words (letters and digits only).
    public let words: Set<String>

    public init(_ text: String) {
        let lowered = text.lowercased()
        self.text = lowered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.words = Set(lowered.split { !($0.isLetter || $0.isNumber) }.map(String.init))
    }

    func containsAny(words list: [String]) -> Bool {
        list.contains(where: words.contains)
    }

    func containsAny(phrases list: [String]) -> Bool {
        list.contains(where: text.contains)
    }

    /// Words printed on till receipts and card-terminal slips.
    static let receiptWords = [
        "receipt", "kassabon", "kassaticket", "kassa", "bon", "pin", "pinnen", "pinbetaling",
        "contant", "wisselgeld", "betaalbewijs", "kwitantie", "quittung", "kassenbon",
        "betaalautomaat", "terminal", "autorisatiecode", "autorisatie", "contactloos", "maestro", "vpay",
        "kaartbetaling", "transactie", "merchant",
    ]
    static let receiptPhrases = [
        "betaald met", "bedankt voor uw aankoop", "bedankt voor uw bezoek", "tot ziens",
        "thank you for shopping", "card payment", "v pay",
    ]
    /// Signals that only appear on real invoices and payment requests. Words that also show
    /// up on till receipts ("te betalen", "factuur op aanvraag", "invoice available") are
    /// deliberately not here.
    static let invoiceWords = [
        "factuurnummer", "factuurdatum", "vervaldatum", "betalingskenmerk", "betalingstermijn",
        "aanslagbiljet", "aanslagnummer", "notanummer", "overmaken", "debiteurnummer",
    ]
    static let invoicePhrases = [
        "invoice number", "invoice date", "invoice no", "please pay", "due date", "payment due",
        "amount due", "payment terms", "t.n.v.", "onder vermelding van", "o.v.v.",
    ]

    /// Receipts often say an invoice is available on request; those mentions don't make
    /// a document an invoice.
    static let invoiceOnRequestPhrases = [
        "factuur op aanvraag", "factuur aanvragen", "geen factuur", "factuur nodig",
        "invoice on request", "invoice available", "not an invoice", "request an invoice",
    ]

    /// "factuur" or "invoice" outside the on-request phrases above.
    var mentionsInvoice: Bool {
        var remaining = text
        for phrase in Self.invoiceOnRequestPhrases {
            remaining = remaining.replacingOccurrences(of: phrase, with: " ")
        }
        let remainingWords = Set(remaining.split { !($0.isLetter || $0.isNumber) }.map(String.init))
        return remainingWords.contains("factuur") || remainingWords.contains("invoice")
    }

    /// True when the text looks like a till or hotel receipt and not like an invoice.
    public var looksLikeReceipt: Bool {
        (containsAny(words: Self.receiptWords) || containsAny(phrases: Self.receiptPhrases))
            && !mentionsInvoice
            && !containsAny(words: Self.invoiceWords)
            && !containsAny(phrases: Self.invoicePhrases)
    }
}
