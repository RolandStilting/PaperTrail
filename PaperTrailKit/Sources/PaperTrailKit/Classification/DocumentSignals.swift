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

    static let receiptWords = [
        "receipt", "kassabon", "kassaticket", "kassa", "bon", "pin", "pinbetaling",
        "contant", "wisselgeld", "betaalbewijs", "kwitantie", "quittung", "kassenbon",
    ]
    static let invoiceWords = [
        "factuur", "factuurnummer", "factuurdatum", "invoice", "vervaldatum",
        "betalingskenmerk", "aanslagbiljet", "aanslagnummer", "notanummer",
    ]
    static let invoicePhrases = ["te betalen", "please pay", "due date", "payment due", "amount due"]

    /// True when the text looks like a till or hotel receipt and not like an invoice.
    public var looksLikeReceipt: Bool {
        containsAny(words: Self.receiptWords)
            && !containsAny(words: Self.invoiceWords)
            && !containsAny(phrases: Self.invoicePhrases)
    }
}
