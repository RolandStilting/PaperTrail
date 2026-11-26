import Foundation

/// A category folder inside an owner's year folder, e.g. "Invoices".
/// Named `DocumentCategory` to avoid clashing with other `Category` types.
public struct DocumentCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Documents in this category get a ledger code from their owner's list (e.g. Invoices
    /// and Receipts); other categories, such as Letters, don't.
    public var usesLedgerCodes: Bool

    public init(id: UUID = UUID(), name: String, usesLedgerCodes: Bool = false) {
        self.id = id
        self.name = name
        self.usesLedgerCodes = usesLedgerCodes
    }

    enum CodingKeys: String, CodingKey { case id, name, usesLedgerCodes }

    /// Settings saved before ledger codes have no switch; it is off.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        usesLedgerCodes = try container.decodeIfPresent(Bool.self, forKey: .usesLedgerCodes) ?? false
    }
}
