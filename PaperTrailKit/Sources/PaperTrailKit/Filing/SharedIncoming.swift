import Foundation

/// The hand-off folder between the Share Extension and the app, inside the App Group
/// container. The extension copies shared files here; the app moves them to Inbox.
public enum SharedIncoming {
    /// Info.plist key holding the App Group identifier (it differs between iOS and macOS).
    public static let appGroupInfoKey = "PTAppGroupIdentifier"
    public static let folderName = "Incoming"
    /// At most this many documents per share, like one email.
    public static let maxDocuments = EmailIntake.maxDocuments

    public enum SaveError: LocalizedError, Equatable {
        case tooLarge(String)
        case notAPDF(String)

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let name): String(localized: "\"\(name)\" is too large (PDFs up to 50 MB, images up to 30 MB).", bundle: .module)
            case .notAPDF(let name): String(localized: "\"\(name)\" is not a valid PDF.", bundle: .module)
            }
        }
    }

    /// Removes `.partial` files left by an extension that stopped mid-copy (older than an hour,
    /// so a copy in progress is left alone).
    public static func removeStalePartials(in folder: URL, now: Date = .now) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in entries where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "partial" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(modified) > 3600 { try? fileManager.removeItem(at: url) }
        }
    }

    /// The same limits as email intake: size per kind, and a PDF must really be one.
    public static func check(_ source: URL, isPDF: Bool) throws {
        let name = source.lastPathComponent
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= (isPDF ? EmailIntake.maxPDFBytes : EmailIntake.maxImageBytes) else { throw SaveError.tooLarge(name) }
        if isPDF {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            guard EmailIntake.looksLikePDF(try handle.read(upToCount: 1024) ?? Data()) else { throw SaveError.notAPDF(name) }
        }
    }

    public static func folder(in groupContainer: URL) -> URL {
        groupContainer.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Copies `source` into `folder` as `preferredName` (or "Shared document"), adding
    /// " (2)" on collisions. Writes to a temporary name first so the app never sees half a file.
    /// - Parameter fileExtension: The extension of the type that was loaded ("pdf", "jpeg"). It
    ///   decides how the app treats the file, so it never comes from the suggested name: an
    ///   image shared as "x.pdf" becomes "x.pdf.jpeg", and "Invoice No. 5" gets ".pdf".
    public static func save(_ source: URL, preferredName: String?, fileExtension: String? = nil, into folder: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (fileExtension ?? FileNamer.splitExtension(source.lastPathComponent).ext).lowercased()
        var name = FileNamer.sanitizeComponent(preferredName ?? "")
        if name.isEmpty { name = String(localized: "Shared document", bundle: .module) }
        if !ext.isEmpty, !name.lowercased().hasSuffix(".\(ext)") { name += ".\(ext)" }

        let staging = folder.appending(path: ".\(UUID().uuidString).partial")
        do {
            try fileManager.copyItem(at: source, to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
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
