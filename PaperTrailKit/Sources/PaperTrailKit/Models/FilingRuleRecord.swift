import Foundation
import SwiftData

/// Stored form of a ``SenderRule``, synced with CloudKit (every property has a default,
/// no unique constraints). Lists are newline-separated strings to keep the schema simple.
@Model
public final class FilingRuleRecord {
    public var id: UUID = UUID()
    public var senderName: String = ""
    public var aliasesText: String = ""
    public var ibansText: String = ""
    public var ownerName: String = ""
    public var categoryName: String = ""
    /// Empty when the sender's expenses are not reimbursed.
    public var reimbursedByName: String = ""
    /// One line per ledger code: owner, category and code separated by tabs.
    public var ledgerCodesText: String = ""
    public var updatedAt: Date = Date.distantPast

    public init(_ rule: SenderRule) {
        update(from: rule)
    }

    public func update(from rule: SenderRule) {
        id = rule.id
        senderName = rule.senderName
        aliasesText = rule.aliases.joined(separator: "\n")
        ibansText = rule.ibans.joined(separator: "\n")
        ownerName = rule.owner
        categoryName = rule.category
        reimbursedByName = rule.reimbursedBy ?? ""
        ledgerCodesText = rule.ledgerCodes.map { [$0.owner, $0.category, $0.code].joined(separator: "\t") }.joined(separator: "\n")
        updatedAt = rule.updatedAt
    }

    public var rule: SenderRule {
        SenderRule(
            id: id, senderName: senderName,
            aliases: aliasesText.split(separator: "\n").map(String.init),
            ibans: ibansText.split(separator: "\n").map(String.init),
            owner: ownerName, category: categoryName,
            reimbursedBy: reimbursedByName.isEmpty ? nil : reimbursedByName,
            ledgerCodes: ledgerCodesText.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return parts.count == 3 ? LedgerChoice(owner: parts[0], category: parts[1], code: parts[2]) : nil
            },
            updatedAt: updatedAt
        )
    }
}
