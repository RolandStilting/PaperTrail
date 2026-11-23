import CoreGraphics
import Foundation
import PaperTrailKit
import SwiftData
import Testing
@testable import PaperTrail

@MainActor
@Suite("ExpenseService")
struct ExpenseServiceTests {
    let container: ModelContainer
    let root: URL
    let service: ExpenseService

    init() throws {
        let schema = Schema(PaperTrailSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Private/2026/Receipts"), withIntermediateDirectories: true)
        service = ExpenseService(location: FilingServiceRuleTests.TempLocation(url: root))
    }

    func expense(_ name: String, amount: Double?, writeFile: Bool = true) throws -> DocumentRecord {
        let path = "Private/2026/Receipts/\(name).pdf"
        if writeFile {
            try PDFBuilder.makePDF(from: [Self.image()]).write(to: root.appending(path: path))
        }
        let record = DocumentRecord(relativePath: path, ownerName: "Private", categoryName: "Receipts", sender: name,
                                    documentDescription: "Kassabon", receivedDate: .now, source: .scan,
                                    bill: amount.map { BillDetails(amount: $0) })
        record.reimbursedBy = "Company1"
        container.mainContext.insert(record)
        return record
    }

    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        return context.makeImage()!
    }

    @Test func claimLifecycle() async throws {
        let a = try expense("Parkeren", amount: 4.5)
        let b = try expense("Bouwmarkt", amount: 49.02)
        #expect(a.claimState == .open)

        let package = try await service.createClaim(company: "Company1", expenses: [a, b], context: container.mainContext)
        let pdf = try #require(CGPDFDocument(CGDataProvider(data: try Data(contentsOf: package.pdf) as CFData)!))
        #expect(pdf.numberOfPages == 3)
        #expect(FileManager.default.fileExists(atPath: package.csv.path(percentEncoded: false)))
        let claim = try #require(try container.mainContext.fetch(FetchDescriptor<ExpenseClaimRecord>()).first)
        #expect(claim.total == 53.52)
        #expect(a.claimState == .submitted && b.claimState == .submitted)

        try service.markReimbursed(claim, expenses: [a, b], context: container.mainContext)
        #expect(a.claimState == .reimbursed && b.claimState == .reimbursed)

        try service.markNotReimbursed(claim, expenses: [a, b], context: container.mainContext)
        #expect(a.claimState == .submitted && b.claimState == .submitted)
        #expect(claim.reimbursedAt == nil)
    }

    @Test func undoReopensExpenses() async throws {
        let a = try expense("Parkeren", amount: 4.5)
        _ = try await service.createClaim(company: "Company1", expenses: [a], context: container.mainContext)
        let claim = try #require(try container.mainContext.fetch(FetchDescriptor<ExpenseClaimRecord>()).first)
        try service.undo(claim, expenses: [a], context: container.mainContext)
        #expect(a.claimState == .open)
        #expect(try container.mainContext.fetch(FetchDescriptor<ExpenseClaimRecord>()).isEmpty)
    }

    @Test func missingReceiptRecordsNothing() async throws {
        let a = try expense("Weg", amount: 4.5, writeFile: false)
        await #expect(throws: ExpenseClaimError.self) {
            _ = try await service.createClaim(company: "Company1", expenses: [a], context: container.mainContext)
        }
        #expect(a.claimState == .open)
        #expect(try container.mainContext.fetch(FetchDescriptor<ExpenseClaimRecord>()).isEmpty)
    }
}

#if os(macOS)
@MainActor
@Suite("ArchiveReset")
struct ArchiveResetTests {
    @Test func trashesFilesAndClearsIndexButKeepsRules() async throws {
        let schema = Schema(PaperTrailSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root.appending(path: "Private/2026/Receipts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Needs Review"), withIntermediateDirectories: true)
        try Data("%PDF-1.7 synthetic".utf8).write(to: root.appending(path: "Private/2026/Receipts/a.pdf"))

        let record = DocumentRecord(relativePath: "Private/2026/Receipts/a.pdf", ownerName: "Private", categoryName: "Receipts",
                                    sender: "Testmarkt", documentDescription: "Bon", receivedDate: .now, source: .scan)
        record.reminderExternalID = "ext-1"
        context.insert(record)
        context.insert(ExpenseClaimRecord(ownerName: "Company1", expenseCount: 1, total: 1))
        context.insert(FilingRuleRecord(SenderRule(senderName: "Testmarkt", aliases: ["testmarkt"], owner: "Private", category: "Receipts")))
        try context.save()

        let reminders = FakeReminders()
        let trash = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTrash-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var reset = ArchiveReset(location: FilingServiceRuleTests.TempLocation(url: root), reminders: reminders)
        reset.moveToTrash = { try FileManager.default.moveItem(at: $0, to: trash.appending(path: $0.lastPathComponent)) }
        let report = try await reset.run(options: ArchiveResetOptions(), context: context)

        #expect(report.trashedItems == 2)
        #expect(report.clearedDocuments == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false)).filter { !$0.hasPrefix(".") }.isEmpty)
        #expect(try context.fetch(FetchDescriptor<DocumentRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ExpenseClaimRecord>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<FilingRuleRecord>()).count == 1)
        #expect(reminders.deleted == ["ext-1"])
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "Private/2026/Receipts/a.pdf").path(percentEncoded: false)))
    }
}
#endif
