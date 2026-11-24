import Foundation
import PaperTrailKit
import SwiftData

/// The index (VAT lines, amounts, paid state, claims, rules …) as plain files next to the
/// PDFs: `Paper Trail/Export/Paper Trail Index.json` and `.csv`, written every week and on
/// request, with dated copies in `Export/Backups/`. Import adds back what is missing.
struct IndexBackup {
    var location: any ArchiveLocating
    /// Records the export time for the weekly schedule; off in tests.
    var recordsExportTime = true

    nonisolated static let jsonName = "Paper Trail Index.json"
    nonisolated static let csvName = "Paper Trail Index.csv"
    nonisolated static let backupsFolderName = "Backups"
    static let interval: TimeInterval = 7 * 24 * 60 * 60
    nonisolated static let keptBackups = 8

    /// Synced with iCloud key-value storage, so a week counts across all devices.
    static let exportedAtKey = "indexExportedAt"
    static let exportedCountKey = "indexExportedDocumentCount"

    enum BackupError: LocalizedError {
        case writeFailed(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .writeFailed(let reason):
                String(localized: "Could not write the index export: \(reason). Check that iCloud Drive has free space and try again.")
            case .unreadable(let name):
                String(localized: "Could not read \"\(name)\". Make sure it is downloaded from iCloud Drive and try again.")
            }
        }
    }

    // MARK: Export

    static var lastExport: Date? {
        let cloud = NSUbiquitousKeyValueStore.default.object(forKey: exportedAtKey) as? Date
        let local = UserDefaults.standard.object(forKey: exportedAtKey) as? Date
        return [cloud, local].compactMap { $0 }.max()
    }

    private static var lastExportedCount: Int {
        max(Int(NSUbiquitousKeyValueStore.default.longLong(forKey: exportedCountKey)), UserDefaults.standard.integer(forKey: exportedCountKey))
    }

    @MainActor
    static func makeExport(context: ModelContext, settings: ArchiveSettings, now: Date = .now) throws -> IndexExport {
        IndexExport(
            exportedAt: now,
            documents: try context.fetch(FetchDescriptor<DocumentRecord>()).map(\.exported),
            expenseClaims: try context.fetch(FetchDescriptor<ExpenseClaimRecord>()).map(\.exported),
            vatReturns: try context.fetch(FetchDescriptor<VATReturnRecord>()).map(\.exported),
            senderRules: try context.fetch(FetchDescriptor<FilingRuleRecord>()).map { IndexExport.Rule($0.rule) },
            settings: settings
        )
    }

    /// Writes the export now. Returns the folder it was written to.
    @discardableResult
    func export(_ export: IndexExport) async throws -> URL {
        let root = try await location.resolveRoot().url
        let folder = root.appending(path: ArchivePaths.exportFolderName, directoryHint: .isDirectory)
        let json = try export.json()
        let csv = export.documentsCSV()
        try await Self.write(json: json, csv: csv, date: export.exportedAt, into: folder)
        if recordsExportTime { Self.remember(export) }
        return folder
    }

    /// The weekly export: only when the last one (from any device) is a week old. Skipped while
    /// this device's index looks incomplete (e.g. still syncing after a new install), so a
    /// half-empty export never replaces a good one.
    @MainActor
    func exportIfDue(context: ModelContext, settings: ArchiveSettings, now: Date = .now) async {
        if let last = Self.lastExport, now.timeIntervalSince(last) < Self.interval { return }
        guard let snapshot = try? Self.makeExport(context: context, settings: settings, now: now),
              !snapshot.documents.isEmpty,
              snapshot.documents.count * 2 >= Self.lastExportedCount else { return }
        // A failed automatic export is tried again next time; Export Now shows the error.
        _ = try? await export(snapshot)
    }

    private static func remember(_ export: IndexExport) {
        UserDefaults.standard.set(export.exportedAt, forKey: exportedAtKey)
        UserDefaults.standard.set(export.documents.count, forKey: exportedCountKey)
        NSUbiquitousKeyValueStore.default.set(export.exportedAt, forKey: exportedAtKey)
        NSUbiquitousKeyValueStore.default.set(Int64(export.documents.count), forKey: exportedCountKey)
    }

    @concurrent
    private static func write(json: Data, csv: Data, date: Date, into folder: URL) async throws {
        let fileManager = FileManager.default
        let backups = folder.appending(path: backupsFolderName, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
        } catch {
            throw BackupError.writeFailed(error.localizedDescription)
        }
        let day = FileNamer().dateString(date)
        try coordinatedWrite(json, to: folder.appending(path: jsonName))
        try coordinatedWrite(csv, to: folder.appending(path: csvName))
        try coordinatedWrite(json, to: backups.appending(path: "Paper Trail Index \(day).json"))
        pruneBackups(in: backups)
    }

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            result = Result { try data.write(to: writeURL, options: .atomic) }
        }
        if let coordinationError { throw BackupError.writeFailed(coordinationError.localizedDescription) }
        do { try result.get() } catch { throw BackupError.writeFailed(error.localizedDescription) }
    }

    /// Keeps the newest dated backups (names sort by date).
    nonisolated private static func pruneBackups(in folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
            .filter { $0.hasPrefix("Paper Trail Index ") && $0.hasSuffix(".json") }
            .sorted()
        for name in names.dropLast(keptBackups) {
            let url = folder.appending(path: name)
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { deleteURL in
                try? FileManager.default.removeItem(at: deleteURL)
            }
        }
    }

    // MARK: Import

    /// Reads an export file (e.g. picked in the file importer) and works out what it would add.
    @MainActor
    func plan(importing url: URL, context: ModelContext) async throws -> (IndexExport, IndexImportPlan) {
        let export = try IndexExport.read(try await Self.read(url))
        let root = try await location.resolveRoot().url
        let documents = try context.fetch(FetchDescriptor<DocumentRecord>())
        let plan = IndexImportPlan(
            export: export,
            documentIDs: Set(documents.map(\.id)), documentPaths: Set(documents.map(\.relativePath)),
            claimIDs: Set(try context.fetch(FetchDescriptor<ExpenseClaimRecord>()).map(\.id)),
            vatReturns: try context.fetch(FetchDescriptor<VATReturnRecord>()).map { (owner: $0.ownerName, start: $0.periodStart) },
            ruleIDs: Set(try context.fetch(FetchDescriptor<FilingRuleRecord>()).map(\.id)),
            fileExists: { Self.fileExists($0, root: root) }
        )
        return (export, plan)
    }

    /// Adds what the plan found missing. Nothing already in the index is changed.
    @MainActor
    static func apply(_ plan: IndexImportPlan, context: ModelContext) throws {
        plan.documents.forEach { context.insert(DocumentRecord(imported: $0)) }
        plan.expenseClaims.forEach { context.insert(ExpenseClaimRecord(imported: $0)) }
        plan.vatReturns.forEach { context.insert(VATReturnRecord(imported: $0)) }
        plan.senderRules.forEach { context.insert(FilingRuleRecord($0.rule)) }
        try context.save()
    }

    /// A file in iCloud Drive that isn't downloaded may exist only as a placeholder.
    nonisolated static func fileExists(_ relativePath: String, root: URL) -> Bool {
        let url = root.appending(path: relativePath)
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            || FileManager.default.fileExists(atPath: placeholder.path(percentEncoded: false))
    }

    @concurrent
    private static func read(_ url: URL) async throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var result: Result<Data, Error> = .failure(BackupError.unreadable(url.lastPathComponent))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        guard coordinationError == nil, let data = try? result.get() else { throw BackupError.unreadable(url.lastPathComponent) }
        return data
    }
}
