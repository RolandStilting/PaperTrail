#if os(macOS)
import Foundation
import PaperTrailKit
import SwiftData

nonisolated enum ArchiveResetError: LocalizedError {
    case couldNotTrash([String])

    var errorDescription: String? {
        switch self {
        case .couldNotTrash(let names):
            String(localized: "Could not move these to the Trash: \(names.joined(separator: ", ")). Nothing was cleared from the index. Check iCloud Drive and try again.")
        }
    }
}

struct ArchiveResetOptions {
    /// Learned sender rules are learned data, not settings; kept unless asked.
    var forgetRules = false
    /// Removes the reminders Paper Trail created for bills.
    var deleteReminders = true
    /// Keeps `Export/` (the index export and its backups): the way back if the reset was a
    /// mistake. Off: it goes to the Trash with the rest, since it holds all document details.
    var keepExport = true
}

struct ArchiveResetReport {
    var trashedItems = 0
    var clearedDocuments = 0
    var reminderProblems: [String] = []
}

/// Clear All Documents, for starting over after testing. Settings (owners, categories, payment,
/// email) stay. Files go to the Trash, not deleted, so they can be restored; on iCloud Drive
/// deleted files can usually also be recovered for a while on iCloud.com. Mac only, where the
/// Trash is reliable.
struct ArchiveReset {
    var location: any ArchiveLocating
    var reminders: any BillReminding
    /// Moves one item to the Trash; replaceable so tests don't fill the user's Trash.
    var moveToTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    func run(options: ArchiveResetOptions, context: ModelContext) async throws -> ArchiveResetReport {
        var report = ArchiveResetReport()
        let root = try await location.resolveRoot().url

        // 1. Files first. If any can't be moved, stop: the index still matches the files left.
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var failures: [String] = []
        for item in entries where !item.lastPathComponent.hasPrefix(".") {
            if options.keepExport, item.lastPathComponent.lowercased() == ArchivePaths.exportFolderName.lowercased() { continue }
            var coordinationError: NSError?
            var trashError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: item, options: .forDeleting, error: &coordinationError) { url in
                do { try moveToTrash(url) } catch { trashError = error }
            }
            if coordinationError != nil || trashError != nil {
                failures.append(item.lastPathComponent)
            } else {
                report.trashedItems += 1
            }
        }
        guard failures.isEmpty else { throw ArchiveResetError.couldNotTrash(failures) }

        // 2. Reminders of bills, if asked. A failure here doesn't stop the reset.
        let documents = try context.fetch(FetchDescriptor<DocumentRecord>())
        if options.deleteReminders {
            for id in Set(documents.compactMap(\.reminderExternalID)) {
                do { try await reminders.deleteReminder(externalID: id) } catch {
                    report.reminderProblems.append(error.localizedDescription)
                }
            }
        }

        // 3. The index.
        report.clearedDocuments = documents.count
        documents.forEach(context.delete)
        try context.fetch(FetchDescriptor<ExpenseClaimRecord>()).forEach(context.delete)
        if options.forgetRules {
            try context.fetch(FetchDescriptor<FilingRuleRecord>()).forEach(context.delete)
        }
        try context.save()
        return report
    }
}
#endif
