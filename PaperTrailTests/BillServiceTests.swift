import Foundation
import PaperTrailKit
import SwiftData
import Testing
@testable import PaperTrail

@MainActor
final class FakeReminders: BillReminding {
    var created: [UUID] = []
    var completed: Set<String> = []

    func createReminder(for bill: DocumentRecord) async throws -> String {
        created.append(bill.id)
        // Real Reminders gives every new reminder its own identifier.
        return created.count == 1 ? "ext-\(bill.id.uuidString)" : "ext-\(bill.id.uuidString)-\(created.count)"
    }

    func completedReminders(among externalIDs: [String]) async throws -> [String: Date] {
        Dictionary(uniqueKeysWithValues: externalIDs.filter(completed.contains).map { ($0, Date.now) })
    }

    func completeReminder(externalID: String) async throws {
        completed.insert(externalID)
    }

    var deleted: Set<String> = []
    func reminderExists(externalID: String) async -> Bool { !deleted.contains(externalID) }
    func deleteReminder(externalID: String) async throws { deleted.insert(externalID) }
    var refreshed: [String] = []
    func refreshText(externalID: String, for bill: DocumentRecord) async throws { refreshed.append(externalID) }
}

@MainActor
@Suite("BillService")
struct BillServiceTests {
    let container: ModelContainer
    let reminders = FakeReminders()
    var service: BillService { BillService(reminders: reminders) }

    init() throws {
        let schema = Schema(PaperTrailSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    func bill(unpaid: Bool = true) -> DocumentRecord {
        let record = DocumentRecord(relativePath: "Private/2026/Invoices/a.pdf", ownerName: "Private", categoryName: "Invoices",
                                    sender: "Praatnet", documentDescription: "Factuur", receivedDate: .now, source: .scan,
                                    bill: BillDetails(isUnpaid: unpaid, amount: 45.99, iban: "NL91ABNA0417164300"))
        container.mainContext.insert(record)
        return record
    }

    @Test func unpaidBillGetsOneReminder() async throws {
        let record = bill()
        try await service.addReminder(for: record, context: container.mainContext)
        try await service.addReminder(for: record, context: container.mainContext)
        #expect(reminders.created == [record.id])
        #expect(record.reminderExternalID == "ext-\(record.id.uuidString)")
    }

    @Test func directDebitGetsNoReminder() async throws {
        let record = bill(unpaid: false)
        try await service.addReminder(for: record, context: container.mainContext)
        #expect(reminders.created.isEmpty)
    }

    @Test func completedReminderMarksBillPaid() async throws {
        let record = bill()
        try await service.addReminder(for: record, context: container.mainContext)
        try await service.syncPaidState(bills: [record], context: container.mainContext)
        #expect(!record.isPaid)
        reminders.completed.insert(record.reminderExternalID!)
        try await service.syncPaidState(bills: [record], context: container.mainContext)
        #expect(record.isPaid)
        #expect(record.paidAt != nil)
    }

    @Test func markingPaidCompletesTheReminder() async throws {
        let record = bill()
        try await service.addReminder(for: record, context: container.mainContext)
        try await service.markPaid(record, context: container.mainContext)
        #expect(record.isPaid)
        #expect(reminders.completed.contains(record.reminderExternalID!))
    }

    @Test func deletedReminderCanBeCreatedAgain() async throws {
        let record = bill()
        try await service.addReminder(for: record, context: container.mainContext)
        let first = try #require(record.reminderExternalID)
        #expect(await !service.reminderIsMissing(for: record))
        reminders.deleted.insert(first)
        #expect(await service.reminderIsMissing(for: record))
        try await service.recreateReminder(for: record, context: container.mainContext)
        #expect(reminders.created.count == 2)
        #expect(await !service.reminderIsMissing(for: record))
    }

    @Test func remindersTurnedOffMakeNoneOnEdit() async throws {
        let record = bill()
        try await service.updateReminder(for: record, change: .create, createsReminders: false, context: container.mainContext)
        #expect(reminders.created.isEmpty && record.reminderExternalID == nil)

        try await service.addReminder(for: record, context: container.mainContext)
        let old = try #require(record.reminderExternalID)
        try await service.updateReminder(for: record, change: .replace, createsReminders: false, context: container.mainContext)
        #expect(reminders.created.count == 1)
        #expect(reminders.deleted == [old] && record.reminderExternalID == nil)
    }

    @Test func oldReminderTextsAreRewrittenOnce() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BillServiceTests-\(UUID().uuidString)"))
        let record = bill()
        try await service.addReminder(for: record, context: container.mainContext)
        await service.refreshOldReminderTexts(bills: [record], defaults: defaults)
        await service.refreshOldReminderTexts(bills: [record], defaults: defaults)
        #expect(reminders.refreshed == [record.reminderExternalID!])
    }
}
