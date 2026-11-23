import Foundation
import PaperTrailKit

/// What one pass over the Inbox folder did.
nonisolated struct InboxReport: Sendable, Equatable {
    var moved = 0
    /// Files left in Inbox because Paper Trail can't read them.
    var unsupported: [String] = []
    /// Problems with individual files; those files stay in Inbox.
    var failures: [String] = []
}

/// Moves documents from `Paper Trail/Inbox/` into Needs Review, converting images to PDF.
///
/// Moving a file is the claim: only one device can move it, so two devices never pick up
/// the same file. Nothing is lost: images are first moved to a hidden claim folder, then
/// converted, written and verified, and only then removed; on failure they go back to Inbox.
nonisolated struct InboxCollector: Sendable {
    var store: any ArchiveFileStoring

    static let claimFolderName = ".claimed"

    static func inbox(in root: URL) -> URL {
        root.appending(path: ArchivePaths.inboxFolderName, directoryHint: .isDirectory)
    }

    @concurrent
    func collect(root: URL) async -> InboxReport {
        let fileManager = FileManager.default
        let inbox = Self.inbox(in: root)
        let needsReview = ReviewQueue.folder(in: root)
        var report = InboxReport()

        // Creating the folder makes the drop zone visible in iCloud Drive.
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: inbox.path(percentEncoded: false)) else {
            report.failures.append(String(localized: "Could not read the Inbox folder. Check iCloud Drive and try again."))
            return report
        }

        for entry in entries.sorted() {
            let url = inbox.appending(path: entry)
            switch InboxEntry(directoryEntry: entry) {
            case .ignored:
                continue
            case .notDownloaded(let name):
                try? fileManager.startDownloadingUbiquitousItem(at: inbox.appending(path: name))
            case .unsupported(let name):
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue {
                    report.unsupported.append(name)
                }
            case .pdf(let name):
                let target = ReviewQueueNames.fileName(savedAt: Self.addedDate(of: url), originalName: name)
                do {
                    if try Self.coordinatedMove(url, toFolder: needsReview, preferredName: target) != nil { report.moved += 1 }
                } catch {
                    report.failures.append(String(localized: "Could not move \"\(name)\" to Needs Review: \(error.localizedDescription)"))
                }
            case .image(let name):
                do {
                    if try await convertImage(url, name: name, root: root) { report.moved += 1 }
                } catch {
                    report.failures.append(error.localizedDescription)
                }
            }
        }
        return report
    }

    /// Returns false when another device took the file first.
    private func convertImage(_ url: URL, name: String, root: URL) async throws -> Bool {
        let added = Self.addedDate(of: url)
        let claimFolder = ReviewQueue.folder(in: root).appending(path: Self.claimFolderName, directoryHint: .isDirectory)
        guard let claimed = try Self.coordinatedMove(url, toFolder: claimFolder, preferredName: name) else { return false }
        do {
            let data = try Self.coordinatedRead(claimed)
            let images = PDFBuilder.images(fromImageData: data)
            guard !images.isEmpty else { throw CaptureError.unsupportedType(name) }
            let pdf = try PDFBuilder.makePDF(from: images)
            let plan = FilingPlan(
                folderComponents: [ArchivePaths.needsReviewFolderName],
                fileName: ReviewQueueNames.fileName(savedAt: added, originalName: name)
            )
            _ = try await store.store(pdf, plan: plan, root: root, removingSource: claimed)
            return true
        } catch {
            // Put the original back so nothing is lost.
            _ = try? Self.coordinatedMove(claimed, toFolder: Self.inbox(in: root), preferredName: name)
            throw error
        }
    }

    static func addedDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        return values?.addedToDirectoryDate ?? values?.creationDate ?? .now
    }

    /// Moves a file under coordination, adding " (2)" on a name collision.
    /// Returns nil when the source is gone, for example because another device moved it.
    static func coordinatedMove(_ source: URL, toFolder folder: URL, preferredName: String) throws -> URL? {
        let fileManager = FileManager.default
        var result: Result<URL?, Error> = .success(nil)
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: folder, options: .forMerging, error: &coordinationError) { sourceURL, folderURL in
            do {
                guard fileManager.fileExists(atPath: sourceURL.path(percentEncoded: false)) else { return }
                try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                var taken = Set(((try? fileManager.contentsOfDirectory(atPath: folderURL.path(percentEncoded: false))) ?? []).map { $0.lowercased() })
                while let name = FileNamer.uniqueFileName(preferredName, exists: { taken.contains($0.lowercased()) }) {
                    let target = folderURL.appending(path: name, directoryHint: .notDirectory)
                    do {
                        coordinator.item(at: sourceURL, willMoveTo: target)
                        try fileManager.moveItem(at: sourceURL, to: target)
                        coordinator.item(at: sourceURL, didMoveTo: target)
                        result = .success(target)
                        return
                    } catch CocoaError.fileWriteFileExists {
                        taken.insert(name.lowercased())
                    }
                }
                result = .failure(ArchiveFileStoreError.tooManyCollisions(preferredName))
            } catch CocoaError.fileNoSuchFile {
                result = .success(nil)
            } catch {
                result = .failure(error)
            }
        }
        if let coordinationError {
            if coordinationError.domain == NSCocoaErrorDomain, coordinationError.code == CocoaError.fileNoSuchFile.rawValue { return nil }
            throw coordinationError
        }
        return try result.get()
    }

    static func coordinatedRead(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
