import Foundation
import PaperTrailKit
import SwiftData
import Testing
@testable import PaperTrail

/// Synthetic documents only.
@MainActor
@Suite("Index export and import")
struct IndexBackupTests {
    let root: URL
    let backup: IndexBackup

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backup = IndexBackup(location: FilingServiceRuleTests.TempLocation(url: root), recordsExportTime: false)
    }

    func container() throws -> ModelContainer {
        let schema = Schema(PaperTrailSchema.models)
        return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    @Test func exportThenRestoreIntoAnEmptyIndex() async throws {
        // A filed bill with VAT, in an index that will be "lost".
        let original = try container()
        let service = FilingService(location: FilingServiceRuleTests.TempLocation(url: root), store: CoordinatedFileStore())
        var request = FilingRequest(owner: "Company1", category: "Invoices", receivedDate: .now, sender: "Voorbeeld Energie", description: "Nota",
                                    bill: BillDetails(isUnpaid: true, amount: 121, iban: "NL00TEST0123456789"))
        request.vat = VATInfo(lines: [VATLine(rate: 21, base: 100, amount: 21)])
        let record = try await service.file(PendingDocument(pdfData: Data("%PDF-1.7 synthetic \(UUID())".utf8), source: .scan),
                                            request: request, extractedText: "nota", context: original.mainContext)

        let export = try IndexBackup.makeExport(context: original.mainContext, settings: .defaults)
        let folder = try await backup.export(export)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        #expect(files.contains("Paper Trail Index.json") && files.contains("Paper Trail Index.csv") && files.contains("Backups"))

        // A fresh, empty index imports it back.
        let restored = try container()
        let jsonURL = folder.appending(path: "Paper Trail Index.json")
        let (_, plan) = try await backup.plan(importing: jsonURL, context: restored.mainContext)
        #expect(plan.documents.count == 1)
        #expect(plan.senderRules.count == 1)
        try IndexBackup.apply(plan, context: restored.mainContext)

        let back = try #require(try restored.mainContext.fetch(FetchDescriptor<DocumentRecord>()).first)
        #expect(back.id == record.id)
        #expect(back.vatInfo?.total == 21)
        #expect(back.amount == 121)
        #expect(back.isOpenBill)

        // Importing again adds nothing.
        let (_, again) = try await backup.plan(importing: jsonURL, context: restored.mainContext)
        #expect(again.isEmpty)
        #expect(again.documentsAlreadyThere == 1)
    }

    @Test func keepsEightWeeklyBackups() async throws {
        let index = try container()
        let calendar = Calendar(identifier: .gregorian)
        for week in 0..<10 {
            let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1 + week * 7, hour: 12))!
            let export = try IndexBackup.makeExport(context: index.mainContext, settings: .defaults, now: date)
            try await backup.export(export)
        }
        let backups = root.appending(path: "Export/Backups")
        let names = try FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false)).sorted()
        #expect(names.count == 8)
        #expect(names.last == "Paper Trail Index 2026-11-03.json")
    }
}
