import Foundation
import PaperTrailKit

/// Where the archive lives on disk.
nonisolated struct ArchiveRoot: Sendable, Equatable {
    var url: URL
    /// True when iCloud Drive is unavailable and a debug build fell back to a local folder.
    var isLocalFallback: Bool
}

nonisolated protocol ArchiveLocating: Sendable {
    func resolveRoot() async throws -> ArchiveRoot
}

nonisolated enum ArchiveLocationError: LocalizedError {
    case iCloudUnavailable

    var errorDescription: String? {
        String(localized: "iCloud Drive is not available. Sign in to iCloud and turn on iCloud Drive for Paper Trail in Settings, then try again.")
    }
}

/// Resolves the archive root in the app's iCloud container. iCloud Drive shows the
/// container's `Documents` folder as "Paper Trail" (see `NSUbiquitousContainers` in Info.plist).
nonisolated struct ICloudArchiveLocation: ArchiveLocating {
    /// `iCloud.<bundle ID>`, written into Info.plist at build time from `PAPERTRAIL_BUNDLE_ID`.
    static let containerIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "PTICloudContainerIdentifier") as? String

    @concurrent
    func resolveRoot() async throws -> ArchiveRoot {
        let fileManager = FileManager.default
        // Must not run on the main thread: the first call can take a while.
        if let identifier = Self.containerIdentifier,
           let container = fileManager.url(forUbiquityContainerIdentifier: identifier) {
            let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
            return ArchiveRoot(url: documents, isLocalFallback: false)
        }
        #if DEBUG
        // Lets the app run in the simulator or without a signing team. Never in release builds.
        let local = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "\(ArchivePaths.archiveDisplayName) (local debug)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: local, withIntermediateDirectories: true)
        return ArchiveRoot(url: local, isLocalFallback: true)
        #else
        throw ArchiveLocationError.iCloudUnavailable
        #endif
    }
}
