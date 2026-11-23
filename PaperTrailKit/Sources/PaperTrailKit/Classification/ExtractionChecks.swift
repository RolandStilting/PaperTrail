import Foundation

/// Rules that run on the model's answer and correct it against the document text.
public enum ExtractionChecks {
    /// Category name used for receipts, if the user's settings have one.
    static func receiptCategory(in categories: [String]) -> String? {
        categories.first { $0.caseInsensitiveCompare("Receipts") == .orderedSame }
    }

    public static func apply(_ extraction: ModelExtraction, text: String, categories: [String]) -> ModelExtraction {
        var result = extraction
        let signals = DocumentSignals(text)

        if signals.looksLikeReceipt, let receipts = receiptCategory(in: categories) {
            result.category = receipts
        }
        // Snap to the exact spelling in the settings; unknown names become empty for review.
        result.category = categories.first { $0.caseInsensitiveCompare(result.category) == .orderedSame } ?? ""

        return result
    }
}
