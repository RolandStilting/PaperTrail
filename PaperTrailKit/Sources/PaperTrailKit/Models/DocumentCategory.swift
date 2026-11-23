import Foundation

/// A category folder inside an owner's year folder, e.g. "Invoices".
/// Named `DocumentCategory` to avoid clashing with other `Category` types.
public struct DocumentCategory: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
