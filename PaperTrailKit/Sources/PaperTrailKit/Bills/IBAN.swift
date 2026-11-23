import Foundation

/// IBAN helpers (ISO 13616): normalising, the mod-97 check and display formatting.
public enum IBAN {
    /// Upper case, letters and digits only.
    public static func normalize(_ value: String) -> String {
        value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// True when the country code and check digits are well-formed and mod 97 equals 1.
    /// This catches typos; it does not prove the account exists.
    public static func isValid(_ value: String) -> Bool {
        let iban = normalize(value)
        guard (15...34).contains(iban.count),
              iban.prefix(2).allSatisfy(\.isLetter),
              iban.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return false }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for character in rearranged {
            let digits: String
            if let digit = character.wholeNumberValue {
                digits = String(digit)
            } else if let ascii = character.asciiValue, character.isLetter {
                digits = String(Int(ascii) - 55)  // A = 10 ... Z = 35
            } else {
                return false
            }
            for d in digits { remainder = (remainder * 10 + Int(String(d))!) % 97 }
        }
        return remainder == 1
    }

    /// "NL91 ABNA 0417 1643 00"
    public static func formatted(_ value: String) -> String {
        let iban = normalize(value)
        return stride(from: 0, to: iban.count, by: 4).map { start in
            let from = iban.index(iban.startIndex, offsetBy: start)
            let to = iban.index(from, offsetBy: min(4, iban.count - start))
            return String(iban[from..<to])
        }.joined(separator: " ")
    }
}
