import Foundation
import SwiftData

/// One expense claim sent to a company. Its expenses point to it with `claimID`.
/// CloudKit-compatible: every property has a default.
@Model
public final class ExpenseClaimRecord {
    public var id: UUID = UUID()
    /// The company that pays the claim back.
    public var ownerName: String = ""
    public var createdAt: Date = Date.distantPast
    public var reimbursedAt: Date?
    public var expenseCount: Int = 0
    public var total: Double = 0

    public init(id: UUID = UUID(), ownerName: String, createdAt: Date = .now, expenseCount: Int, total: Double) {
        self.id = id
        self.ownerName = ownerName
        self.createdAt = createdAt
        self.expenseCount = expenseCount
        self.total = total
    }
}

/// All SwiftData models, so the app and tests use the same schema.
public enum PaperTrailSchema {
    public static let models: [any PersistentModel.Type] = [DocumentRecord.self, FilingRuleRecord.self, ExpenseClaimRecord.self]
}
