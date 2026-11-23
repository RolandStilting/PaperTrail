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
        return "ext-\(bill.id.uuidString)"
    }

    func completedReminders(among externalIDs: [String]) async throws -> [String: Date] {
        Dictionary(uniqueKeysWithValues: externalIDs.filter(completed.contains).map { ($0, Date.now) })
    }

    func completeReminder(externalID: String) async throws {
        completed.insert(externalID)
    }
}

@MainActor
@Suite("BillService")
struct BillServiceTests {
    let container: ModelContainer
    let reminders = FakeReminders()
    var service: BillService { BillService(reminders: reminders) }

    init() throws {
        let schema = Schema([DocumentRecord.self, FilingRuleRecord.self])
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
}
