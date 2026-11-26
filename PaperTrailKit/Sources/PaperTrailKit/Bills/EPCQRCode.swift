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
        // Every field is one line, so text from the invoice must not contain line breaks:
        // a name or reference with one could otherwise push its own IBAN or amount into the
        // following fields.
        let name = String(oneLine(name).prefix(70))
        guard !name.isEmpty else { throw .missingName }
        let iban = IBAN.normalize(iban)
        guard IBAN.isValid(iban) else { throw .invalidIBAN }

        var amountText = ""
        if let amount {
            guard (0.01...999_999_999.99).contains(amount) else { throw .amountOutOfRange }
            amountText = "EUR" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
        }

        let reference = oneLine(reference)
        let isCreditorReference = reference.uppercased().hasPrefix("RF") && reference.count <= 35
        let structured = isCreditorReference ? reference.uppercased().filter { !$0.isWhitespace } : ""
        let unstructured = isCreditorReference ? "" : String(reference.prefix(140))

        let lines = [
            "BCD",                         // service tag
            "002",                         // version (BIC optional within the EEA)
            "1",                           // character set: UTF-8
            "SCT",                         // SEPA credit transfer
            validBIC(bic),
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

    /// Control characters (line breaks, tabs) become spaces; runs of spaces become one.
    static func oneLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}" ? " " : Character(scalar)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A BIC is 8 or 11 letters and digits; anything else is left out (the field is optional).
    static func validBIC(_ bic: String) -> String {
        let bic = IBAN.normalize(bic).uppercased()
        let ok = (bic.count == 8 || bic.count == 11) && bic.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return ok ? bic : ""
    }
}
