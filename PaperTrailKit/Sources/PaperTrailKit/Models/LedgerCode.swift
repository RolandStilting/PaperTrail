import Foundation

/// A ledger account (grootboekrekening) a document can be booked on, e.g. "4300 Telephone
/// and internet". Lists are optional, per owner and category; the admin department books the
/// document on the chosen code.
public struct LedgerCode: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var code: String
    public var description: String

    public init(id: UUID = UUID(), code: String, description: String = "") {
        self.id = id
        self.code = code
        self.description = description
    }

    /// "4300 – Telephone and internet", or just the code.
    public var label: String {
        description.isEmpty ? code : "\(code) – \(description)"
    }

    /// The same code, ignoring case and surrounding spaces.
    public func matches(_ other: String) -> Bool {
        Self.key(code) == Self.key(other)
    }

    static func key(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// The ledger codes one owner uses for one category. Keyed by the category's ID, so renaming
/// the category keeps its list.
public struct LedgerCodeList: Codable, Hashable, Sendable {
    public var categoryID: UUID
    public var codes: [LedgerCode]

    public init(categoryID: UUID, codes: [LedgerCode] = []) {
        self.categoryID = categoryID
        self.codes = codes
    }
}

extension Owner {
    /// The owner's codes for a category; empty when it has none.
    public func ledgerCodes(categoryID: UUID) -> [LedgerCode] {
        ledgerLists.first { $0.categoryID == categoryID }?.codes ?? []
    }

    /// Replaces the codes for a category; an empty list removes it.
    public mutating func setLedgerCodes(_ codes: [LedgerCode], categoryID: UUID) {
        ledgerLists.removeAll { $0.categoryID == categoryID }
        if !codes.isEmpty { ledgerLists.append(LedgerCodeList(categoryID: categoryID, codes: codes)) }
    }
}

extension ArchiveSettings {
    /// Codes for documents of `owner` in `category` (by name, as stored on documents).
    /// Empty when that combination has no list: then there is no ledger code to choose.
    public func ledgerCodes(owner: String, category: String) -> [LedgerCode] {
        guard let owner = owners.first(where: { $0.name == owner }),
              let category = categories.first(where: { $0.name == category }) else { return [] }
        return owner.ledgerCodes(categoryID: category.id)
    }

    /// Settings ready to save: rows without code or description dropped, codes and
    /// descriptions trimmed, lists of removed categories and empty lists removed.
    public func cleaningLedgerCodes() -> ArchiveSettings {
        var settings = self
        let categoryIDs = Set(categories.map(\.id))
        for index in settings.owners.indices {
            settings.owners[index].ledgerLists = settings.owners[index].ledgerLists.compactMap { list in
                guard categoryIDs.contains(list.categoryID) else { return nil }
                let codes = list.codes.compactMap { code -> LedgerCode? in
                    var code = code
                    code.code = code.code.trimmingCharacters(in: .whitespacesAndNewlines)
                    code.description = code.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    return code.code.isEmpty && code.description.isEmpty ? nil : code
                }
                return codes.isEmpty ? nil : LedgerCodeList(categoryID: list.categoryID, codes: codes)
            }
        }
        return settings
    }

    /// Problems with the ledger code lists, as user-facing messages.
    var ledgerCodeErrors: [String] {
        var errors: [String] = []
        for owner in owners {
            for list in owner.ledgerLists {
                let category = categories.first { $0.id == list.categoryID }?.name ?? ""
                let codes = list.codes.map { LedgerCode.key($0.code) }
                if list.codes.contains(where: { LedgerCode.key($0.code).isEmpty && !$0.description.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    errors.append(String(localized: "A ledger code for \(owner.name) › \(category) has a description but no code. Enter the code or remove the row.", bundle: .module))
                }
                let filled = codes.filter { !$0.isEmpty }
                if Set(filled).count != filled.count {
                    errors.append(String(localized: "Two ledger codes for \(owner.name) › \(category) are the same. Make each code unique.", bundle: .module))
                }
            }
        }
        return errors
    }
}
