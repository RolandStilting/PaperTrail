import Foundation
import PaperTrailKit

/// One document waiting in `Paper Trail/Needs Review/`.
nonisolated struct ReviewItem: Identifiable, Hashable, Sendable {
    var url: URL
    var name: String
    var savedDate: Date?
    /// False while iCloud has only a placeholder on this device.
    var isDownloaded: Bool
    var id: URL { url }
}

nonisolated enum ReviewQueueError: LocalizedError {
    case alreadyHandled(String)
    case notInQueue(String)

    var errorDescription: String? {
        switch self {
        case .alreadyHandled(let name):
            String(localized: "\"\(name)\" is no longer in Needs Review. It was probably filed on another device. Pull down to refresh the list.")
        case .notInQueue(let name):
            String(localized: "\"\(name)\" is not in the Needs Review folder, so Paper Trail won't delete it.")
        }
    }
}

/// The review queue is the Needs Review folder: documents are saved there to be filed later,
/// and filing one moves it out (write, verify, then remove).
nonisolated struct ReviewQueue: Sendable {
    var store: any ArchiveFileStoring

    static func folder(in root: URL) -> URL {
        root.appending(path: ArchivePaths.needsReviewFolderName, directoryHint: .isDirectory)
    }

    /// Queued PDFs, newest first. A missing folder means an empty queue.
    @concurrent
    func items(root: URL) async throws -> [ReviewItem] {
        let folder = Self.folder(in: root)
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
        return entries.compactMap { entry -> ReviewItem? in
            guard let name = ReviewQueueNames.itemName(forDirectoryEntry: entry) else { return nil }
            return ReviewItem(
                url: folder.appending(path: name), name: name,
                savedDate: ReviewQueueNames.savedDate(fromFileName: name),
                isDownloaded: entry == name
            )
        }
        .reduce(into: [URL: ReviewItem]()) { result, item in
            // A file can briefly show up both as placeholder and as download; keep the download.
            if result[item.url]?.isDownloaded != true { result[item.url] = item }
        }
        .values
        .sorted { $0.name > $1.name }
    }

    /// Saves a captured document to Needs Review without filing it.
    func add(_ document: PendingDocument, root: URL, now: Date = .now) async throws -> StoredFile {
        let plan = FilingPlan(
            folderComponents: [ArchivePaths.needsReviewFolderName],
            fileName: ReviewQueueNames.fileName(savedAt: now, originalName: document.originalName)
        )
        return try await store.store(document.pdfData, plan: plan, root: root, removingSource: nil)
    }

    /// Moves a queued document to the Trash (on iCloud Drive: Recently Deleted in Files), for
    /// a duplicate or something that doesn't need filing. Only files directly in the Needs
    /// Review folder can be deleted this way.
    @concurrent
    func delete(_ url: URL, root: URL) async throws {
        let folder = Self.folder(in: root).standardizedFileURL.resolvingSymlinksInPath()
        let target = url.standardizedFileURL
        guard target.deletingLastPathComponent().resolvingSymlinksInPath() == folder,
              ReviewQueueNames.itemName(forDirectoryEntry: target.lastPathComponent) != nil else {
            throw ReviewQueueError.notInQueue(url.lastPathComponent)
        }
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw ReviewQueueError.alreadyHandled(url.lastPathComponent)
        }
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { url in
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch CocoaError.featureUnsupported {
                // A volume without a Trash (e.g. the local folder a debug build uses without iCloud).
                do { try FileManager.default.removeItem(at: url) } catch { failure = error }
            } catch {
                failure = error
            }
        }
        if let error = coordinationError ?? failure { throw error }
    }

    /// Reads a queued document for the filing screen, downloading it from iCloud if needed.
    @concurrent
    func open(_ item: ReviewItem) async throws -> PendingDocument {
        if !item.isDownloaded {
            // Coordinated reading also downloads, but asking first lets iCloud start right away.
            try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
        }
        var document = try await DocumentCapture.fromFile(at: item.url)
        document.reviewItemURL = item.url
        document.receivedDate = item.savedDate
        document.originalName = item.name
        return document
    }
}
