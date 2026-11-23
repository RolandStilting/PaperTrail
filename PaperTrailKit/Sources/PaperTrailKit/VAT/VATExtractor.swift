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
        let lines = lowered.components(separatedBy: .newlines)
        var found: [VATLine] = []

        for (index, rawLine) in lines.enumerated() {
            let (hasDutch, hasForeign) = vatWords(in: rawLine)
            guard hasDutch || hasForeign else { continue }

            var line: VATLine?
            if let (rate, rest) = percentage(in: rawLine) {
                line = vatLine(rate: rate, amounts: moneyAmounts(in: rest), total: total)
                // PDF tables often put the amount on the next line: "BTW 21%" / "€ 5,03".
                if line == nil, index + 1 < lines.count, percentage(in: lines[index + 1]) == nil,
                   !vatWords(in: lines[index + 1]).0, !vatWords(in: lines[index + 1]).1 {
                    line = vatLine(rate: rate, amounts: moneyAmounts(in: lines[index + 1]), total: total)
                }
                if let rate = line?.rate, hasForeign || !dutchRates.contains(rate) { info.isForeign = true }
            } else if let total, !rawLine.contains("incl"), !rawLine.contains("excl") {
                // "BTW € 5,03" without a rate: accept it only when it fits a Dutch rate of the total.
                let amounts = moneyAmounts(in: rawLine)
                for rate in [21.0, 9.0] {
                    if let vat = amounts.first(where: { abs(total * rate / (100 + rate) - $0) <= 0.02 }) {
                        line = VATLine(rate: rate, base: ((total - vat) * 100).rounded() / 100, amount: vat)
                        break
                    }
                }
                if line != nil, hasForeign { info.isForeign = true }
            }
            if let line, !found.contains(line) { found.append(line) }
        }
        info.lines = merged(found)
        return info
    }

    static func vatWords(in line: String) -> (dutch: Bool, foreign: Bool) {
        let words = Set(line.split { !$0.isLetter }.map(String.init))
        let dutch = ["btw", "vat", "omzetbelasting"].contains(where: words.contains) || line.contains("b.t.w.")
        let foreign = foreignWords.contains(where: words.contains)
        return (dutch, foreign)
    }

    /// One line per rate. When a line equals the sum of the others with that rate (item lines
    /// plus a total line), only that line counts, so VAT is never counted twice; otherwise the
    /// lines are added up.
    static func merged(_ lines: [VATLine]) -> [VATLine] {
        var result: [VATLine] = []
        for rate in lines.map(\.rate).reduce(into: [Double](), { if !$0.contains($1) { $0.append($1) } }) {
            let group = lines.filter { $0.rate == rate }
            guard group.count > 1 else { result += group; continue }
            let cents = group.map { Int(($0.amount * 100).rounded()) }
            if let index = cents.indices.first(where: { cents[$0] * 2 == cents.reduce(0, +) }) {
                result.append(group[index])
                continue
            }
            let bases = group.compactMap(\.base)
            result.append(VATLine(
                rate: rate,
                base: bases.count == group.count ? Double(bases.map { Int(($0 * 100).rounded()) }.reduce(0, +)) / 100 : nil,
                amount: Double(cents.reduce(0, +)) / 100
            ))
        }
        return result
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
        // A lone amount is the VAT only if it can be: never more than the rate of the total
        // (so "Totaal incl. 21% btw € 121,00" is not read as VAT).
        guard amounts.count == 1 else { return nil }
        if let total, amounts[0] > total * rate / 100 + 0.02 { return nil }
        return VATLine(rate: rate, amount: amounts[0])
    }
}
