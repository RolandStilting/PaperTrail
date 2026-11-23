import Foundation

/// The hand-off folder between the Share Extension and the app, inside the App Group
/// container. The extension copies shared files here; the app moves them to Inbox.
public enum SharedIncoming {
    /// Info.plist key holding the App Group identifier (it differs between iOS and macOS).
    public static let appGroupInfoKey = "PTAppGroupIdentifier"
    public static let folderName = "Incoming"

    public static func folder(in groupContainer: URL) -> URL {
        groupContainer.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Copies `source` into `folder` as `preferredName` (or "Shared document"), adding
    /// " (2)" on collisions. Writes to a temporary name first so the app never sees half a file.
    public static func save(_ source: URL, preferredName: String?, into folder: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceExt = FileNamer.splitExtension(source.lastPathComponent).ext
        var name = FileNamer.sanitizeComponent(preferredName ?? "")
        if name.isEmpty { name = String(localized: "Shared document", bundle: .module) }
        if FileNamer.splitExtension(name).ext.isEmpty, !sourceExt.isEmpty { name += ".\(sourceExt)" }

        let staging = folder.appending(path: ".\(UUID().uuidString).partial")
        try fileManager.copyItem(at: source, to: staging)
        var taken = Set(((try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).map { $0.lowercased() })
        while let candidate = FileNamer.uniqueFileName(name, exists: { taken.contains($0.lowercased()) }) {
            let target = folder.appending(path: candidate)
            do {
                try fileManager.moveItem(at: staging, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                taken.insert(candidate.lowercased())
            }
        }
        try? fileManager.removeItem(at: staging)
        throw CocoaError(.fileWriteFileExists)
    }
}
