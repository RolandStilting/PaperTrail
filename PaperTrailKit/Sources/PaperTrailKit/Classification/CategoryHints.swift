import Foundation

/// Short explanations of the default categories, added to the model instructions so it
/// can tell similar categories apart (for example Receipts and Invoices).
/// Categories the user adds have no hint; the model then only sees the name.
public enum CategoryHints {
    static let hints: [String: String] = [
        "invoices": "a bill or invoice from a company, usually with an invoice number; it may still have to be paid or may already be paid",
        "receipts": "proof of a payment made on the spot, such as a till receipt from a shop, restaurant, hotel or petrol station",
        "letters": "general correspondence that is not a bill, contract or tax document",
        "contracts": "an agreement between parties, such as a rental, employment or service contract",
        "tax": "documents from a tax authority or municipality, such as a tax assessment (aanslag) or tax return",
        "insurance": "insurance policies, premium overviews and insurance claims",
        "bank": "letters and statements from a bank about accounts, cards or loans",
        "other": "anything that fits none of the other categories",
    ]

    public static func hint(for category: String) -> String? {
        hints[category.lowercased()]
    }

    /// One line per category: "- Name: hint" or just "- Name".
    public static func describe(_ categories: [String]) -> String {
        categories.map { name in
            if let hint = hint(for: name) { "- \(name): \(hint)" } else { "- \(name)" }
        }.joined(separator: "\n")
    }
}
