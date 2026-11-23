import Foundation

/// What the user confirmed in the filing screen.
public struct FilingRequest: Sendable, Hashable {
    public var owner: String
    public var category: String
    public var receivedDate: Date
    public var documentDate: Date?
    public var sender: String
    public var description: String

    public init(owner: String, category: String, receivedDate: Date, documentDate: Date? = nil, sender: String, description: String) {
        self.owner = owner
        self.category = category
        self.receivedDate = receivedDate
        self.documentDate = documentDate
        self.sender = sender
        self.description = description
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
