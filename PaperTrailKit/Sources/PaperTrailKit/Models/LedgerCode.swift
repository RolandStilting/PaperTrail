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

/// Ledger codes as stored before they moved from per category to per owner (2026-11-24).
/// Only read, to move old lists into the owner's single list.
struct LegacyLedgerCodeList: Codable, Hashable, Sendable {
    var categoryID: UUID
    var codes: [LedgerCode]
}

extension ArchiveSettings {
    /// Codes for documents of `owner` in `category` (by name, as stored on documents): the
    /// owner's list when the category uses ledger codes, else empty (no code to choose).
    public func ledgerCodes(owner: String, category: String) -> [LedgerCode] {
        guard let owner = owners.first(where: { $0.name == owner }),
              categories.first(where: { $0.name == category })?.usesLedgerCodes == true else { return [] }
        return owner.ledgerCodes
    }

    /// Settings ready to save: rows without code or description dropped, codes and
    /// descriptions trimmed, empty VAT codes removed.
    public func cleaningLedgerCodes() -> ArchiveSettings {
        var settings = self
        for index in settings.owners.indices {
            settings.owners[index].ledgerCodes = settings.owners[index].ledgerCodes.compactMap { code in
                var code = code
                code.code = code.code.trimmingCharacters(in: .whitespacesAndNewlines)
                code.description = code.description.trimmingCharacters(in: .whitespacesAndNewlines)
                return code.code.isEmpty && code.description.isEmpty ? nil : code
            }
            for vatCode in settings.owners[index].vatLedgerCodes {
                settings.owners[index].setVATLedgerCode(vatCode.code.trimmingCharacters(in: .whitespacesAndNewlines), rate: vatCode.rate)
            }
        }
        return settings
    }

    /// Problems with the ledger codes, as user-facing messages.
    var ledgerCodeErrors: [String] {
        var errors: [String] = []
        for owner in owners {
            if owner.ledgerCodes.contains(where: { LedgerCode.key($0.code).isEmpty && !$0.description.trimmingCharacters(in: .whitespaces).isEmpty }) {
                errors.append(String(localized: "A ledger code for \(owner.name) has a description but no code. Enter the code or remove the row.", bundle: .module))
            }
            let filled = owner.ledgerCodes.map { LedgerCode.key($0.code) }.filter { !$0.isEmpty }
            if Set(filled).count != filled.count {
                errors.append(String(localized: "Two ledger codes for \(owner.name) are the same. Make each code unique.", bundle: .module))
            }
        }
        return errors
    }

    /// Settings saved with per-category lists: each owner gets one list (all codes, the first
    /// of each code kept), and the categories that had a list use ledger codes.
    mutating func moveLegacyLedgerLists() {
        for index in owners.indices where !owners[index].legacyLedgerLists.isEmpty {
            for list in owners[index].legacyLedgerLists {
                for code in list.codes where !owners[index].ledgerCodes.contains(where: { $0.matches(code.code) }) {
                    owners[index].ledgerCodes.append(code)
                }
                if let category = categories.firstIndex(where: { $0.id == list.categoryID }) {
                    categories[category].usesLedgerCodes = true
                }
            }
            owners[index].legacyLedgerLists = []
        }
    }
}

/// The ledger code input VAT at one rate is booked on, e.g. 21 % → "1510".
public struct VATLedgerCode: Codable, Hashable, Sendable {
    /// Percentage, e.g. 21 or 9.
    public var rate: Double
    public var code: String

    public init(rate: Double, code: String) {
        self.rate = rate
        self.code = code
    }

    /// The Dutch rates with reclaimable VAT that get a code in Settings.
    public static let rates: [Double] = [21, 9]
}

extension Owner {
    /// The input VAT ledger code for `rate`, or nil when none is set.
    public func vatLedgerCode(rate: Double) -> String? {
        vatLedgerCodes.first { abs($0.rate - rate) < 0.001 && !$0.code.isEmpty }?.code
    }

    /// Sets the code for `rate`; an empty code removes it.
    public mutating func setVATLedgerCode(_ code: String, rate: Double) {
        vatLedgerCodes.removeAll { abs($0.rate - rate) < 0.001 }
        if !code.isEmpty { vatLedgerCodes.append(VATLedgerCode(rate: rate, code: code)) }
        vatLedgerCodes.sort { $0.rate > $1.rate }
    }
}

extension ArchiveSettings {
    /// The company a document is booked by: the company that reimburses it (a receipt paid
    /// privately), else its own owner. Its ledger codes and VAT codes apply.
    public static func bookingOwner(owner: String, reimbursedBy: String?) -> String {
        guard let reimbursedBy, !reimbursedBy.isEmpty else { return owner }
        return reimbursedBy
    }

    /// Input VAT ledger code of `owner` for `rate`.
    public func vatLedgerCode(owner: String, rate: Double) -> String? {
        owners.first { $0.name == owner }?.vatLedgerCode(rate: rate)
    }
}
