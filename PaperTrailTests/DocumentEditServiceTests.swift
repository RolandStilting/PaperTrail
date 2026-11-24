import Foundation
import PaperTrailKit
import SwiftData
import Testing
@testable import PaperTrail

/// Synthetic documents only.
@MainActor
@Suite("Editing filed documents")
struct DocumentEditServiceTests {
    let container: ModelContainer
    let root: URL
    let service: FilingService
    let reminders = FakeReminders()
    var context: ModelContext { container.mainContext }

    init() throws {
        let schema = Schema(PaperTrailSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = FilingService(location: FilingServiceRuleTests.TempLocation(url: root), store: CoordinatedFileStore())
    }

    func date(_ day: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day))! }

    func fileDocument(_ request: FilingRequest) async throws -> DocumentRecord {
        let document = PendingDocument(pdfData: Data("%PDF-1.7 synthetic \(UUID())".utf8), source: .fileImport)
        return try await service.file(document, request: request, extractedText: "Voorbeeld Energie jaarnota", context: context)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relativePath).path(percentEncoded: false))
    }

    @Test func renamesAndMovesTheFile() async throws {
        let request = FilingRequest(owner: "Private", category: "Letters", receivedDate: date(23), sender: "Voorbeeld Energi", description: "Brief")
        let record = try await fileDocument(request)
        let oldPath = record.relativePath

        var changed = request
        changed.owner = "Company1"
        changed.category = "Invoices"
        changed.sender = "Voorbeeld Energie"
        changed.description = "Jaarnota"
        try await service.update(record, request: changed, context: context)

        #expect(record.relativePath == "Company1/2026/Invoices/2026-11-23 Voorbeeld Energie - Jaarnota.pdf")
        #expect(exists(record.relativePath))
        #expect(!exists(oldPath))
        #expect(record.ownerName == "Company1")
        #expect(record.sender == "Voorbeeld Energie")
        // The correction is learned, with the old spelling as alias.
        let rule = try #require(try context.fetch(FetchDescriptor<FilingRuleRecord>()).map(\.rule).first)
        #expect(rule.owner == "Company1")
        #expect(rule.aliases.contains("voorbeeld energi"))
    }

    @Test func unchangedNameKeepsCollisionNumberAndCollisionsAreNumbered() async throws {
        let request = FilingRequest(owner: "Private", category: "Invoices", receivedDate: date(23), sender: "Testmarkt", description: "Bon")
        let first = try await fileDocument(request)
        let second = try await fileDocument(request)
        #expect(second.relativePath.hasSuffix("Bon (2).pdf"))

        // Only the amount changes: the file stays where it is.
        var amountOnly = request
        amountOnly.bill = BillDetails(amount: 12.5)
        try await service.update(second, request: amountOnly, context: context)
        #expect(second.relativePath.hasSuffix("Bon (2).pdf"))
        #expect(second.amount == 12.5)

        // Renaming the first to a name that is taken gets a number.
        var other = request
        other.description = "Kassabon"
        try await service.update(first, request: other, context: context)
        var back = other
        back.description = "Bon"
        try await service.update(first, request: back, context: context)
        #expect(first.relativePath.hasSuffix("Bon.pdf") || first.relativePath.hasSuffix("Bon (3).pdf"))
        #expect(exists(first.relativePath))
        #expect(exists(second.relativePath))
    }

    @Test func missingFileIsReportedAndNothingChanges() async throws {
        let request = FilingRequest(owner: "Private", category: "Invoices", receivedDate: date(23), sender: "Testmarkt", description: "Bon")
        let record = try await fileDocument(request)
        try FileManager.default.removeItem(at: root.appending(path: record.relativePath))
        var changed = request
        changed.description = "Andere bon"
        await #expect(throws: ArchiveFileStoreError.self) { try await service.update(record, request: changed, context: context) }
        #expect(record.documentDescription == "Bon")
    }

    @Test func reminderFollowsTheBill() async throws {
        let bills = BillService(reminders: reminders)
        let request = FilingRequest(owner: "Private", category: "Invoices", receivedDate: date(23), sender: "Voorbeeld Energie", description: "Nota",
                                    bill: BillDetails(isUnpaid: true, amount: 42.5, iban: "NL00TEST0123456789"))
        let record = try await fileDocument(request)
        try await bills.addReminder(for: record, context: context)
        let firstID = try #require(record.reminderExternalID)

        // Amount corrected: a new reminder replaces the old one.
        var corrected = request
        corrected.bill?.amount = 45
        let before = record.reminderFacts
        try await service.update(record, request: corrected, context: context)
        let change = DocumentEdit.reminderChange(before: before, after: record.reminderFacts, wasUnpaidBill: true, isUnpaidBill: true, isPaid: false, hasReminder: true)
        try await bills.updateReminder(for: record, change: change, context: context)
        #expect(change == .replace)
        #expect(record.reminderExternalID != firstID)
        #expect(reminders.deleted == [firstID])

        // No longer a bill: the reminder goes.
        let secondID = try #require(record.reminderExternalID)
        try await bills.updateReminder(for: record, change: .remove, context: context)
        #expect(record.reminderExternalID == nil)
        #expect(reminders.deleted.contains(secondID))
    }
}
