import Foundation

/// What the user confirmed in the filing screen.
public struct FilingRequest: Sendable, Hashable {
    public var owner: String
    public var category: String
    public var receivedDate: Date
    public var documentDate: Date?
    public var sender: String
    public var description: String
    /// Payment details, if the user confirmed any.
    public var bill: BillDetails?
    /// The company that reimburses this expense, if any.
    public var reimbursedBy: String?
    /// VAT lines, for documents of VAT-registered owners (or expenses they reimburse).
    public var vat: VATInfo?
    /// The ledger code to book on, if the owner has codes for the category and one was chosen.
    public var ledger: LedgerCode?
    /// True when the owner has ledger codes for the category: then an empty `ledger` means the
    /// user chose none, and the learned code for the sender is forgotten.
    public var offersLedgerCodes: Bool = false

    public init(owner: String, category: String, receivedDate: Date, documentDate: Date? = nil, sender: String, description: String,
                bill: BillDetails? = nil, reimbursedBy: String? = nil, vat: VATInfo? = nil, ledger: LedgerCode? = nil) {
        self.owner = owner
        self.category = category
        self.receivedDate = receivedDate
        self.documentDate = documentDate
        self.sender = sender
        self.description = description
        self.bill = bill
        self.reimbursedBy = reimbursedBy
        self.vat = vat
        self.ledger = ledger
    }
}

/// Where a document will be written, before collision handling.
public struct FilingPlan: Sendable, Hashable {
    public var folderComponents: [String]
    public var fileName: String

    public init(folderComponents: [String], fileName: String) {
        self.folderComponents = folderComponents
        self.fileName = fileName
    }

    public var relativePath: String {
        ArchivePaths.relativePath(components: folderComponents, fileName: fileName)
    }
}

public enum FilingError: LocalizedError, Equatable, Sendable {
    case missingOwner
    case missingCategory
    case reservedOwnerName(String)

    public var errorDescription: String? {
        switch self {
        case .missingOwner:
            String(localized: "Choose an owner before filing.", bundle: .module)
        case .missingCategory:
            String(localized: "Choose a category before filing.", bundle: .module)
        case .reservedOwnerName(let name):
            String(localized: "\"\(name)\" is a reserved folder name. Rename the owner in Settings.", bundle: .module)
        }
    }
}

public enum FilingPlanner {
    public static func plan(for request: FilingRequest, namer: FileNamer = FileNamer()) throws(FilingError) -> FilingPlan {
        let owner = FileNamer.sanitizeComponent(request.owner)
        let category = FileNamer.sanitizeComponent(request.category)
        guard !owner.isEmpty else { throw .missingOwner }
        guard !category.isEmpty else { throw .missingCategory }
        guard !ArchivePaths.reservedTopLevelNames.contains(owner.lowercased()) else { throw .reservedOwnerName(owner) }

        return FilingPlan(
            folderComponents: ArchivePaths.folderComponents(owner: owner, year: namer.year(of: request.receivedDate), category: category),
            fileName: namer.fileName(receivedDate: request.receivedDate, sender: request.sender, description: request.description)
        )
    }
}
