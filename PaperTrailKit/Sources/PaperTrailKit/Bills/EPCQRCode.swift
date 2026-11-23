import Foundation

/// The text inside a European Payments Council QR code for a SEPA credit transfer
/// (EPC069-12, also known as GiroCode). A banking app that supports it fills in the transfer.
public enum EPCQRCode {
    public enum PayloadError: Error, Equatable, Sendable {
        case missingName
        case invalidIBAN
        case amountOutOfRange
    }

    /// Payloads larger than this don't fit the standard.
    static let maximumBytes = 331

    /// - Parameters:
    ///   - reference: An ISO 11649 creditor reference ("RF…") goes in the structured field;
    ///     anything else, such as a Dutch betalingskenmerk, goes in the free-text field.
    public static func payload(name: String, iban: String, bic: String = "", amount: Double?, reference: String = "") throws(PayloadError) -> String {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70))
        guard !name.isEmpty else { throw .missingName }
        let iban = IBAN.normalize(iban)
        guard IBAN.isValid(iban) else { throw .invalidIBAN }

        var amountText = ""
        if let amount {
            guard (0.01...999_999_999.99).contains(amount) else { throw .amountOutOfRange }
            amountText = "EUR" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
        }

        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCreditorReference = reference.uppercased().hasPrefix("RF") && reference.count <= 35
        let structured = isCreditorReference ? reference.uppercased().filter { !$0.isWhitespace } : ""
        let unstructured = isCreditorReference ? "" : String(reference.prefix(140))

        let lines = [
            "BCD",                         // service tag
            "002",                         // version (BIC optional within the EEA)
            "1",                           // character set: UTF-8
            "SCT",                         // SEPA credit transfer
            IBAN.normalize(bic),
            name,
            iban,
            amountText,
            "",                            // purpose code
            structured,
            unstructured,
        ]
        // Trailing empty fields may be left out.
        var trimmed = lines
        while trimmed.last == "" { trimmed.removeLast() }
        var payload = trimmed.joined(separator: "\n")
        while payload.utf8.count > maximumBytes, !payload.isEmpty { payload.removeLast() }
        return payload
    }
}
