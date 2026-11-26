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

    /// "Pay KPN". Amount and IBAN are left out on purpose: reminders show on the lock screen
    /// and in notifications, and the payment details are in Paper Trail itself.
    public static func title(sender: String) -> String {
        String(localized: "Pay \(sender)", bundle: .module)
    }

    /// The payment reference and where the document is, one per line; an empty reference is
    /// left out. No amount or IBAN (see `title(sender:)`).
    public static func notes(reference: String?, relativePath: String) -> String {
        var lines: [String] = []
        if let reference, !reference.isEmpty {
            lines.append(String(localized: "Reference: \(reference)", bundle: .module))
        }
        lines.append(String(localized: "Document: \(ArchivePaths.archiveDisplayName)/\(relativePath)", bundle: .module))
        return lines.joined(separator: "\n")
    }
}
