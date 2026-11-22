import Foundation

/// A person or company that documents are filed for, e.g. "Private" or a company name.
/// Each owner gets its own top-level folder in the archive.
public struct Owner: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
