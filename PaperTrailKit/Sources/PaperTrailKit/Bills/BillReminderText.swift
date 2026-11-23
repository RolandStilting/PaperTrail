import Foundation

/// Text for the Apple Reminders reminder of an unpaid bill.
public enum BillReminderText {
    /// One list per owner, e.g. "To pay – Company1".
    public static func listName(owner: String) -> String {
        String(localized: "To pay – \(owner)", bundle: .module)
    }

    /// "€ 142,37" in Dutch, "€142.37" in English: follows the user's locale.
    public static func amount(_ amount: Double, locale: Locale = .current) -> String {
        amount.formatted(.currency(code: "EUR").locale(locale))
    }

    /// "Pay KPN · € 45,99", or "Pay KPN" without an amount.
    public static func title(sender: String, amount: Double?, locale: Locale = .current) -> String {
        guard let amount, amount > 0 else { return String(localized: "Pay \(sender)", bundle: .module) }
        return String(localized: "Pay \(sender) · \(Self.amount(amount, locale: locale))", bundle: .module)
    }

    /// Payment details and where the document is, one per line. Empty details are left out.
    public static func notes(amount: Double?, iban: String?, reference: String?, relativePath: String, locale: Locale = .current) -> String {
        var lines: [String] = []
        if let amount, amount > 0 {
            lines.append(String(localized: "Amount: \(Self.amount(amount, locale: locale))", bundle: .module))
        }
        if let iban, !iban.isEmpty {
            lines.append(String(localized: "IBAN: \(IBAN.formatted(iban))", bundle: .module))
        }
        if let reference, !reference.isEmpty {
            lines.append(String(localized: "Reference: \(reference)", bundle: .module))
        }
        lines.append(String(localized: "Document: \(ArchivePaths.archiveDisplayName)/\(relativePath)", bundle: .module))
        return lines.joined(separator: "\n")
    }
}
