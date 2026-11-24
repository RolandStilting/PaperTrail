import Foundation

/// User-editable settings for the archive layout.
///
/// Renaming an owner or category only affects documents filed afterwards;
/// existing folders are not renamed.
public struct ArchiveSettings: Codable, Hashable, Sendable {
    public var owners: [Owner]
    public var categories: [DocumentCategory]

    public init(owners: [Owner], categories: [DocumentCategory]) {
        self.owners = owners
        self.categories = categories
    }

    public static let defaults = ArchiveSettings(
        owners: ["Company1", "Company2", "Private"].map { Owner(name: $0) },
        categories: ["Invoices", "Receipts", "Letters", "Contracts", "Tax", "Insurance", "Bank", "Other"]
            .map { DocumentCategory(name: $0) }
    )

    /// The colour of an owner: its own choice, else automatic by position.
    public func color(ofOwner name: String) -> OwnerColor {
        guard let index = owners.firstIndex(where: { $0.name == name }) else { return .gray }
        return owners[index].color ?? .automatic(index: index)
    }

    /// Problems that stop the settings from being saved, as user-facing messages.
    public var validationErrors: [String] {
        var errors: [String] = []
        let ownerNames = owners.map { FileNamer.sanitizeComponent($0.name) }
        let categoryNames = categories.map { FileNamer.sanitizeComponent($0.name) }

        if owners.isEmpty {
            errors.append(String(localized: "Add at least one owner.", bundle: .module))
        }
        if ownerNames.contains(where: \.isEmpty) {
            errors.append(String(localized: "Every owner needs a name.", bundle: .module))
        }
        if Self.hasDuplicates(ownerNames) {
            errors.append(String(localized: "Two owners have the same name. Make each owner name unique.", bundle: .module))
        }
        if ownerNames.contains(where: { ArchivePaths.reservedTopLevelNames.contains($0.lowercased()) }) {
            errors.append(String(localized: "\"Inbox\" and \"Needs Review\" are reserved folder names. Pick another owner name.", bundle: .module))
        }

        for owner in owners {
            let iban = owner.payingAccount.iban
            if !iban.isEmpty, !IBAN.isValid(iban) {
                errors.append(String(localized: "The IBAN for \(owner.name) is not valid. Check it for typos.", bundle: .module))
            }
            if owner.paymentMethod == .sepaFile, owner.payingAccount.name.isEmpty || iban.isEmpty {
                errors.append(String(localized: "\(owner.name) pays with a SEPA file. Enter the account name and IBAN it pays from.", bundle: .module))
            }
        }

        if categories.isEmpty {
            errors.append(String(localized: "Add at least one category.", bundle: .module))
        }
        if categoryNames.contains(where: \.isEmpty) {
            errors.append(String(localized: "Every category needs a name.", bundle: .module))
        }
        if Self.hasDuplicates(categoryNames) {
            errors.append(String(localized: "Two categories have the same name. Make each category name unique.", bundle: .module))
        }
        errors += ledgerCodeErrors
        return errors
    }

    private static func hasDuplicates(_ names: [String]) -> Bool {
        let lowered = names.filter { !$0.isEmpty }.map { $0.lowercased() }
        return Set(lowered).count != lowered.count
    }
}
