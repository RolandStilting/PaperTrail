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
        updatedAt = rule.updatedAt
    }

    public var rule: SenderRule {
        SenderRule(
            id: id, senderName: senderName,
            aliases: aliasesText.split(separator: "\n").map(String.init),
            ibans: ibansText.split(separator: "\n").map(String.init),
            owner: ownerName, category: categoryName, updatedAt: updatedAt
        )
    }
}
