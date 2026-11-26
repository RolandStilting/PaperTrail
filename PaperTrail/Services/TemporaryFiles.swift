import Foundation

/// Copies of documents Paper Trail makes outside the archive: expense claims and VAT exports
/// for the share sheet, and staging files while filing. They are only needed for a moment, so
/// whatever is left from earlier runs is removed at launch.
nonisolated enum TemporaryFiles {
    static let claimsFolder = "Claims"
    static let vatFolder = "VAT"

    /// Removes the claim and VAT export folders, and staged PDFs older than an hour (a filing
    /// that is still running in another process is left alone).
    static func cleanUp(in temporary: URL = FileManager.default.temporaryDirectory, now: Date = .now) {
        let fileManager = FileManager.default
        for folder in [claimsFolder, vatFolder] {
            try? fileManager.removeItem(at: temporary.appending(path: folder, directoryHint: .isDirectory))
        }
        let entries = (try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in entries where url.pathExtension.lowercased() == "pdf" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > 3600 { try? fileManager.removeItem(at: url) }
        }
    }
}
