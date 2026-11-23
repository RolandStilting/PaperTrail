import Foundation

/// Rules that run on the model's answer and correct it against the document text.
/// The model reads Dutch well but guesses: it invents due dates, treats direct debits as
/// unpaid bills and takes the recipient's own IBAN. These checks only keep values that
/// can be found in the text and override the model where a keyword rule is more reliable.
public enum ExtractionChecks {
    /// Labels before a payment deadline, strongest first. "vervaldatum" comes last because
    /// reminders often mention the old due date with it.
    static let deadlineLabels = [
        "uiterlijk", "vóór", "voor", "no later than", "before", "betalen voor", "due by", "pay by",
        "vervaldatum", "due date", "payment due",
    ]
    static let documentDateLabels = [
        "factuurdatum", "invoice date", "dagtekening", "notadatum", "datum", "date",
    ]
    static let directDebitPhrases = [
        "automatisch af", "automatische incasso", "incasso", "afgeschreven", "direct debit",
        "will be debited", "collected automatically",
    ]

    /// Category name used for receipts, if the user's settings have one.
    static func receiptCategory(in categories: [String]) -> String? {
        categories.first { $0.caseInsensitiveCompare("Receipts") == .orderedSame }
    }

    public static func apply(_ extraction: ModelExtraction, text: String, categories: [String]) -> ModelExtraction {
        var result = extraction
        let signals = DocumentSignals(text)
        let textDates = Set(TextDates.all(in: text).map(\.date))

        // Category
        if signals.looksLikeReceipt, let receipts = receiptCategory(in: categories) {
            result.category = receipts
        }
        // Snap to the exact spelling in the settings; unknown names become empty for review.
        result.category = categories.first { $0.caseInsensitiveCompare(result.category) == .orderedSame } ?? ""

        // Sender: drop legal forms and departments the model kept.
        result.sender = SenderNormalizer.normalize(result.sender)

        // Document date: keep it only if it is in the text; otherwise look next to a label.
        if !textDates.contains(result.documentDate.trimmingCharacters(in: .whitespaces)) {
            result.documentDate = TextDates.date(after: documentDateLabels, in: text) ?? ""
        }

        // Unpaid: receipts and direct debits never need a manual payment.
        if signals.looksLikeReceipt || signals.containsAny(phrases: directDebitPhrases) {
            result.isUnpaidBill = false
        }

        // Amount: keep it only if it is written in the text.
        if result.amount != 0, !amountAppears(result.amount, in: signals.text) {
            result.amount = 0
        }

        if result.isUnpaidBill {
            // Due date: a date after "uiterlijk" or "vóór" beats the model's pick.
            if let deadline = TextDates.date(after: deadlineLabels, in: text) {
                result.dueDate = deadline
            } else if !textDates.contains(result.dueDate) {
                result.dueDate = ""
            }
            // IBAN: must appear in the text.
            let iban = result.iban.uppercased().filter { $0.isLetter || $0.isNumber }
            let squashedText = text.uppercased().filter { $0.isLetter || $0.isNumber }
            result.iban = !iban.isEmpty && squashedText.contains(iban) ? iban : ""
        } else {
            result.dueDate = ""
            result.iban = ""
        }

        // Reference: a Dutch "betalingskenmerk" is what the bank transfer needs.
        if let kenmerk = value(after: "betalingskenmerk", in: text) {
            result.reference = kenmerk
        }

        return result
    }

    /// True when `amount` is written in `text` as 1234,56 / 1.234,56 / 1234.56 / 1,234.56
    /// (or as a whole number when it has no cents). `text` must be lowercased.
    static func amountAppears(_ amount: Double, in text: String) -> Bool {
        let cents = Int((abs(amount) * 100).rounded())
        let whole = cents / 100
        let fraction = String(format: "%02d", cents % 100)
        let plain = String(whole)
        var grouped = plain
        var index = grouped.count - 3
        while index > 0 {
            grouped.insert("#", at: grouped.index(grouped.startIndex, offsetBy: index))
            index -= 3
        }
        var candidates: Set<String> = []
        for separator in [",", "."] {
            let other = separator == "," ? "." : ","
            candidates.insert(plain + separator + fraction)
            candidates.insert(grouped.replacingOccurrences(of: "#", with: other) + separator + fraction)
            candidates.insert(grouped.replacingOccurrences(of: "#", with: " ") + separator + fraction)
        }
        if cents % 100 == 0 {
            candidates.insert(plain + ",-")
            candidates.insert(grouped.replacingOccurrences(of: "#", with: "."))
            candidates.insert(plain)
        }
        let digitBoundary = CharacterSet.decimalDigits
        return candidates.contains { candidate in
            var start = text.startIndex
            while let range = text.range(of: candidate, range: start..<text.endIndex) {
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                let isDigit: (Character?) -> Bool = { $0.map { $0.unicodeScalars.allSatisfy(digitBoundary.contains) } ?? false }
                if !isDigit(before), !isDigit(after) { return true }
                start = range.upperBound
            }
            return false
        }
    }

    /// Letters and digits on the same line after `label` (and an optional colon), without spaces.
    static func value(after label: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: label, options: .caseInsensitive) else { continue }
            let rest = line[range.upperBound...].drop { $0 == ":" || $0.isWhitespace }
            let value = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "." })
                .filter { !$0.isWhitespace }
            if !value.isEmpty { return value }
        }
        return nil
    }
}
