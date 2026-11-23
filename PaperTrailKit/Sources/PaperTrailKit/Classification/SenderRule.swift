import Foundation

/// A rule learned from a filed document: documents from this sender go to this owner and
/// category. Rules run before the model and win over its suggestions.
public struct SenderRule: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// The sender name as the user confirmed it, e.g. "Praatnet".
    public var senderName: String
    /// Lowercased names that identify the sender in document text, e.g. "praatnet demo".
    public var aliases: [String]
    /// IBANs the sender asked to be paid on, without spaces. A strong identifier.
    public var ibans: [String]
    public var owner: String
    public var category: String
    /// Company that reimburses expenses from this sender, if the user marked them so.
    public var reimbursedBy: String?
    public var updatedAt: Date

    public init(id: UUID = UUID(), senderName: String, aliases: [String] = [], ibans: [String] = [],
                owner: String, category: String, reimbursedBy: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.senderName = senderName
        self.aliases = aliases
        self.ibans = ibans
        self.owner = owner
        self.category = category
        self.reimbursedBy = reimbursedBy
        self.updatedAt = updatedAt
    }
}

/// What the user confirmed when filing, used to learn a rule.
public struct ConfirmedFiling: Sendable, Hashable {
    public var sender: String
    /// The sender as the model or a rule suggested it, if different spelling.
    public var suggestedSender: String
    public var owner: String
    public var category: String
    /// IBAN of an unpaid bill (pay-to account). Leave empty otherwise: an IBAN on a direct
    /// debit or bank letter is the recipient's own account and must not identify a sender.
    public var payToIban: String
    /// The company the user chose to reimburse this expense; nil when not reimbursable.
    public var reimbursedBy: String?

    public init(sender: String, suggestedSender: String = "", owner: String, category: String, payToIban: String = "", reimbursedBy: String? = nil) {
        self.sender = sender
        self.suggestedSender = suggestedSender
        self.owner = owner
        self.category = category
        self.payToIban = payToIban
        self.reimbursedBy = reimbursedBy
    }
}

public enum SenderRules {
    /// Aliases shorter than this are ignored; "KPN" still works, "AB" does not.
    static let minimumAliasLength = 3

    static func alias(_ name: String) -> String {
        name.lowercased().split { !($0.isLetter || $0.isNumber) }.joined(separator: " ")
    }

    static func iban(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The rule for the sender of `text`, if any. A matching IBAN beats a name; among names
    /// the longest match wins, then the most recently updated rule.
    public static func match(_ rules: [SenderRule], text: String) -> SenderRule? {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        let wordText = " " + words.joined(separator: " ") + " "
        let squashed = iban(text)

        // An IBAN identifies a sender only if no other sender uses it: payment providers collect
        // for many companies on one IBAN, and then the name must decide.
        var ibanOwners: [String: Set<String>] = [:]
        for rule in rules {
            for iban in rule.ibans { ibanOwners[iban, default: []].insert(alias(rule.senderName)) }
        }

        var best: (rule: SenderRule, score: Int)?
        for rule in rules {
            var score = 0
            if rule.ibans.contains(where: { !$0.isEmpty && squashed.contains($0) && (ibanOwners[$0]?.count ?? 0) == 1 }) {
                score = 1_000
            }
            for alias in rule.aliases where alias.count >= minimumAliasLength && wordText.contains(" \(alias) ") {
                score = max(score, alias.count)
            }
            guard score > 0 else { continue }
            if let current = best, current.score > score || (current.score == score && current.rule.updatedAt >= rule.updatedAt) {
                continue
            }
            best = (rule, score)
        }
        return best?.rule
    }

    /// The rule to save after a confirmed filing: the existing rule for this sender, updated,
    /// or a new one. Returns nil when there is no usable sender name.
    public static func learn(from filing: ConfirmedFiling, existing: [SenderRule], now: Date = .now) -> SenderRule? {
        let names = [filing.sender, filing.suggestedSender, SenderNormalizer.normalize(filing.sender)]
            .map(alias).filter { $0.count >= minimumAliasLength }
        guard let primary = names.first, !filing.owner.isEmpty, !filing.category.isEmpty else { return nil }
        let payTo = iban(filing.payToIban)

        // Merge only with a rule for the same name. A shared IBAN (a payment provider) must never
        // merge two senders into one rule.
        var rule = existing
            .filter { $0.aliases.contains(primary) }
            .max { $0.updatedAt < $1.updatedAt }
            ?? SenderRule(senderName: filing.sender, owner: filing.owner, category: filing.category, updatedAt: now)

        rule.senderName = filing.sender.trimmingCharacters(in: .whitespaces)
        rule.owner = filing.owner
        rule.category = filing.category
        rule.reimbursedBy = filing.reimbursedBy
        rule.updatedAt = now
        for name in names where !rule.aliases.contains(name) { rule.aliases.append(name) }
        if !payTo.isEmpty, !rule.ibans.contains(payTo) { rule.ibans.append(payTo) }
        return rule
    }
}
