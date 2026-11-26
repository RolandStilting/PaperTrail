import Foundation
import PaperTrailKit

/// Watches the Inbox and Needs Review folders in iCloud Drive while the app is in front.
///
/// Reading a folder only shows what iCloud has already brought to this device; on iPhone and
/// iPad it often doesn't fetch another device's new files until something asks for that folder.
/// An iCloud metadata query does ask, and reports changes as iCloud learns of them, so the
/// review list follows other devices within seconds instead of minutes.
///
/// It runs only while the calling task runs (RootView: while the app is active) and costs
/// nothing in between: no polling, the system sends a notification when something changes.
@MainActor
enum ICloudFolderWatcher {
    /// Calls `onChange` when iCloud reports a change in Inbox or Needs Review, until the task
    /// is cancelled. Does nothing for the local debug folder (not in iCloud).
    static func watch(root: ArchiveRoot, onChange: () async -> Void) async {
        guard !root.isLocalFallback else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // The archive root is the container's Documents folder. Match by path text, so a
        // "/private" prefix in the reported paths doesn't matter.
        let folders = [ArchivePaths.inboxFolderName, ArchivePaths.needsReviewFolderName]
        query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: folders.map {
            NSPredicate(format: "%K CONTAINS %@", NSMetadataItemPathKey, "/Documents/\($0)/")
        })
        // Several files arriving together give one update.
        query.notificationBatchingInterval = 1

        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        let observers = [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate].map { name in
            center.addObserver(forName: name, object: query, queue: .main) { _ in continuation.yield() }
        }
        defer {
            query.stop()
            observers.forEach(center.removeObserver)
            continuation.finish()
        }
        guard query.start() else { return }
        for await _ in changes {
            await onChange()
        }
    }
}
