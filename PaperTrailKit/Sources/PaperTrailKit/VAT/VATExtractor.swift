import Foundation

/// One VAT line of a document: e.g. 21 % over € 705,50 = € 148,16.
public struct VATLine: Codable, Hashable, Sendable {
    /// Percentage, e.g. 21 or 9.
    public var rate: Double
    /// Amount excluding VAT, when the document states it.
    public var base: Double?
    public var amount: Double

    public init(rate: Double, base: Double? = nil, amount: Double) {
        self.rate = rate
        self.base = base
        self.amount = amount
    }
}

/// The VAT details of a document, as found in its text and confirmed by the user.
public struct VATInfo: Codable, Hashable, Sendable {
    public var lines: [VATLine]
    /// VAT from another country (German MwSt, a 19 % rate, …): not reclaimable in the Dutch return.
    public var isForeign: Bool
    /// "BTW verlegd" / reverse charge: the buyer accounts for the VAT.
    public var isReverseCharge: Bool

    public init(lines: [VATLine] = [], isForeign: Bool = false, isReverseCharge: Bool = false) {
        self.lines = lines
        self.isForeign = isForeign
        self.isReverseCharge = isReverseCharge
    }

    public var total: Double { (lines.map { ($0.amount * 100).rounded() }.reduce(0, +)) / 100 }
    public var isEmpty: Bool { lines.isEmpty && !isForeign && !isReverseCharge }

    /// Compact storage for the index: JSON, empty when there is nothing.
    public var encoded: String {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> VATInfo? {
        guard !text.isEmpty else { return nil }
        return try? JSONDecoder().decode(VATInfo.self, from: Data(text.utf8))
    }
}

/// Finds VAT lines in document text with rules: a VAT word, a percentage and amounts on one line.
/// Rules work better than the model here: receipts often have several rates, and every value
/// must literally appear in the text.
public enum VATExtractor {
    public static let dutchRates: Set<Double> = [0, 9, 21]
    static let dutchWords = ["btw", "b.t.w.", "vat", "omzetbelasting"]
    static let foreignWords = ["mwst", "ust", "mehrwertsteuer", "umsatzsteuer", "tva", "iva"]
    static let reverseChargePhrases = [
        "btw verlegd", "verlegd naar", "reverse charge", "reverse-charge", "vat reverse charged",
        "steuerschuldnerschaft des leistungsempfängers", "autoliquidation",
    ]

    public static func extract(from text: String, total: Double? = nil) -> VATInfo {
        var info = VATInfo()
        let lowered = text.lowercased()
        info.isReverseCharge = reverseChargePhrases.contains { lowered.contains($0) }

        for rawLine in lowered.components(separatedBy: .newlines) {
            let words = Set(rawLine.split { !($0.isLetter || $0 == ".") }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
            let hasDutch = dutchWords.contains { words.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: "."))) } || rawLine.contains("b.t.w.")
            let hasForeign = foreignWords.contains { words.contains($0) }
            guard hasDutch || hasForeign, let (rate, rest) = percentage(in: rawLine) else { continue }
            let amounts = moneyAmounts(in: rest)
            guard let line = vatLine(rate: rate, amounts: amounts, total: total) else { continue }
            if !info.lines.contains(line) { info.lines.append(line) }
            if hasForeign || !dutchRates.contains(rate) { info.isForeign = true }
        }
        return info
    }

    /// The first percentage in the line, and the line with it removed (so "21" isn't read as money).
    static func percentage(in line: String) -> (Double, String)? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2}(?:[.,]\d{1,2})?)\s?%"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line), let numberRange = Range(match.range(at: 1), in: line),
              let rate = Double(line[numberRange].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        var rest = line
        rest.replaceSubrange(range, with: " ")
        return (rate, rest)
    }

    /// Amounts written with two decimals: 1,97 / 148.16 / 2.318,40 / 1,234.56.
    static func moneyAmounts(in line: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\d.,])(\d{1,3}(?:[.,\s]\d{3})+|\d+)[.,](\d{2})(?![\d%])"#) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let whole = Range(match.range(at: 1), in: line), let cents = Range(match.range(at: 2), in: line) else { return nil }
            let digits = line[whole].filter(\.isNumber)
            return Double("\(digits).\(line[cents])")
        }
    }

    /// Picks base and VAT from a line's amounts: a pair where VAT ≈ base × rate wins; otherwise
    /// an amount that fits the document total; otherwise a single amount is the VAT.
    static func vatLine(rate: Double, amounts: [Double], total: Double?) -> VATLine? {
        guard !amounts.isEmpty else { return nil }
        if rate == 0 {
            guard amounts.contains(0) || amounts.count == 1 else { return nil }
            return VATLine(rate: 0, base: amounts.first { $0 > 0 } ?? total, amount: 0)
        }
        for base in amounts {
            for vat in amounts where vat < base {
                // VAT on top of the base ("21 % over 100,00 → 21,00") …
                if abs(base * rate / 100 - vat) <= 0.02 {
                    return VATLine(rate: rate, base: base, amount: vat)
                }
                // … or contained in a gross amount ("enthaltene MwSt 7 % auf 180,00 → 11,78").
                if abs(base * rate / (100 + rate) - vat) <= 0.02 {
                    return VATLine(rate: rate, base: (base * 100 - vat * 100).rounded() / 100, amount: vat)
                }
            }
        }
        if let total, let vat = amounts.first(where: { abs(total * rate / (100 + rate) - $0) <= 0.02 }) {
            return VATLine(rate: rate, base: (total * 100 - vat * 100).rounded() / 100, amount: vat)
        }
        return amounts.count == 1 ? VATLine(rate: rate, amount: amounts[0]) : nil
    }
}
