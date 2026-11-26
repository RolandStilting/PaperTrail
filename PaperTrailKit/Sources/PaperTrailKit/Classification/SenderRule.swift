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
    /// The ledger code last chosen for this sender, per owner (each company has its own codes;
    /// a sender's invoices and receipts share one).
    public var ledgerCodes: [LedgerChoice]
    /// Hosts of payment pages (links and QR codes) this sender's bills used and the user
    /// accepted, e.g. "pay.example-psp.test". A new host gets a warning.
    public var paymentHosts: [String]
    public var updatedAt: Date

    public init(id: UUID = UUID(), senderName: String, aliases: [String] = [], ibans: [String] = [],
                owner: String, category: String, reimbursedBy: String? = nil, ledgerCodes: [LedgerChoice] = [],
                paymentHosts: [String] = [], updatedAt: Date = .now) {
        self.id = id
        self.senderName = senderName
        self.aliases = aliases
        self.ibans = ibans
        self.owner = owner
        self.category = category
        self.reimbursedBy = reimbursedBy
        self.ledgerCodes = ledgerCodes
        self.paymentHosts = paymentHosts
        self.updatedAt = updatedAt
    }

    /// The code this sender's documents for `owner` were last booked on.
    public func ledgerCode(owner: String) -> String? {
        ledgerCodes.last { $0.owner == owner }?.code
    }

    /// Remembers `code` for the owner; an empty code forgets it.
    public mutating func setLedgerCode(_ code: String, owner: String) {
        ledgerCodes.removeAll { $0.owner == owner }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty { ledgerCodes.append(LedgerChoice(owner: owner, code: code)) }
    }
}

/// A ledger code remembered for one owner.
public struct LedgerChoice: Codable, Hashable, Sendable {
    public var owner: String
    public var code: String

    public init(owner: String, code: String) {
        self.owner = owner
        self.code = code
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
    /// The user confirmed a pay-to IBAN that differs from the ones known for this sender; only
    /// then is it learned. (A sender's first IBAN is learned without asking.)
    public var ibanConfirmed: Bool = false
    /// The ledger code chosen; "" when the user left it empty (forget the learned one), nil
    /// when no code could be chosen (no codes, or a category without them): leave the rule alone.
    public var ledgerCode: String?

    public init(sender: String, suggestedSender: String = "", owner: String, category: String, payToIban: String = "", reimbursedBy: String? = nil,
                ledgerCode: String? = nil) {
        self.sender = sender
        self.suggestedSender = suggestedSender
        self.owner = owner
        self.category = category
        self.payToIban = payToIban
        self.reimbursedBy = reimbursedBy
        self.ledgerCode = ledgerCode
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
    /// After the user corrected a sender's name on a filed document: rules other than `kept`
    /// stop claiming the old name, so the corrected rule is the one that matches. Returns the
    /// changed rules; a rule left without names is no longer useful and can be removed.
    public static func releasing(oldName: String, keeping kept: UUID, in rules: [SenderRule]) -> [SenderRule] {
        let name = alias(oldName)
        return rules.compactMap { rule in
            guard rule.id != kept, rule.aliases.contains(name) else { return nil }
            var changed = rule
            changed.aliases.removeAll { $0 == name }
            return changed
        }
    }

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
        if let code = filing.ledgerCode {
            rule.setLedgerCode(code, owner: ArchiveSettings.bookingOwner(owner: filing.owner, reimbursedBy: filing.reimbursedBy))
        }
        rule.updatedAt = now
        for name in names where !rule.aliases.contains(name) { rule.aliases.append(name) }
        // A changed IBAN is how invoice fraud works: learn it only once the user confirmed it.
        if !payTo.isEmpty, !rule.ibans.contains(payTo), rule.ibans.isEmpty || filing.ibanConfirmed { rule.ibans.append(payTo) }
        return rule
    }
}

// MARK: Fraud checks

/// How a bill's pay-to IBAN compares with what Paper Trail knows about the sender.
public enum IBANCheck: Equatable, Sendable {
    /// No rule for this sender yet, or no IBAN to check.
    case nothingKnown
    case known
    /// The sender is known with other IBANs: the classic sign of invoice fraud.
    case changed(known: [String])
}

/// How a payment page's host compares with the hosts this sender's bills used before.
public enum PaymentHostCheck: Equatable, Sendable {
    case nothingKnown
    case known
    case new(known: [String])
}

extension SenderRules {
    /// The rule for a sender by name (as confirmed by the user), the most recent one first.
    public static func rule(forSender name: String, in rules: [SenderRule]) -> SenderRule? {
        let key = alias(name)
        guard key.count >= minimumAliasLength else { return nil }
        return rules.filter { $0.aliases.contains(key) || alias($0.senderName) == key }.max { $0.updatedAt < $1.updatedAt }
    }

    public static func checkIBAN(_ value: String, rule: SenderRule?) -> IBANCheck {
        let iban = iban(value)
        guard let rule, !iban.isEmpty, !rule.ibans.isEmpty else { return .nothingKnown }
        return rule.ibans.contains(iban) ? .known : .changed(known: rule.ibans)
    }

    /// Adds a confirmed IBAN to the rule.
    public static func confirming(iban value: String, in rule: SenderRule, now: Date = .now) -> SenderRule {
        var rule = rule
        let iban = iban(value)
        if !iban.isEmpty, !rule.ibans.contains(iban) { rule.ibans.append(iban); rule.updatedAt = now }
        return rule
    }

    static func host(_ value: String) -> String {
        var host = value.lowercased().trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public static func checkPaymentHost(_ value: String, rule: SenderRule?) -> PaymentHostCheck {
        let host = host(value)
        guard let rule, !host.isEmpty, !rule.paymentHosts.isEmpty else { return .nothingKnown }
        return rule.paymentHosts.contains(host) ? .known : .new(known: rule.paymentHosts)
    }

    /// Adds a payment host the user accepted (opened the page, or paid the bill with its code).
    public static func accepting(paymentHost value: String, in rule: SenderRule, now: Date = .now) -> SenderRule {
        var rule = rule
        let host = host(value)
        if !host.isEmpty, !rule.paymentHosts.contains(host) { rule.paymentHosts.append(host); rule.updatedAt = now }
        return rule
    }
}
