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

    /// Whether `path` can be a filed document's place in the archive: a PDF inside an owner's
    /// folder (`Owner/YYYY/Category/name.pdf`), relative, without `.`/`..` steps, empty parts or control characters, and not in
    /// Inbox, Needs Review or Export. Used for paths read from an index import, which could
    /// have been edited to point at files outside the archive.
    public static func isDocumentPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), path.lowercased().hasSuffix(".pdf"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        // Owner/YYYY/Category/name.pdf, as FilingPlanner makes them.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") }),
              parts[1].count == 4, parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber) else { return false }
        return !reservedTopLevelNames.contains(parts[0].lowercased())
    }
}
