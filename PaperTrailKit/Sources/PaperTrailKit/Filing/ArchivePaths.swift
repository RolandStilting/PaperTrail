import Foundation

/// Folder layout inside the archive root.
///
/// The archive root is the app's iCloud container `Documents` folder, which iCloud Drive
/// shows as "Paper Trail". Below it: `<Owner>/<Year>/<Category>/`, plus `Inbox/` and
/// `Needs Review/` and `Export/`.
public enum ArchivePaths {
    public static let archiveDisplayName = "Paper Trail"
    public static let inboxFolderName = "Inbox"
    public static let needsReviewFolderName = "Needs Review"
    /// The weekly index export (JSON + CSV) and its dated backups.
    public static let exportFolderName = "Export"

    /// Lowercased top-level names that owners may not use.
    public static let reservedTopLevelNames: Set<String> = [
        inboxFolderName.lowercased(), needsReviewFolderName.lowercased(), exportFolderName.lowercased(),
    ]

    /// Relative folder components for a filed document, e.g. `["Private", "2026", "Invoices"]`.
    public static func folderComponents(owner: String, year: Int, category: String) -> [String] {
        [FileNamer.sanitizeComponent(owner), String(format: "%04d", year), FileNamer.sanitizeComponent(category)]
    }

    public static func relativePath(components: [String], fileName: String) -> String {
        (components + [fileName]).joined(separator: "/")
    }
}
