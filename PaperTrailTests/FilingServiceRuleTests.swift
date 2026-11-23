import CoreGraphics
import Foundation
import ImageIO
import PaperTrailKit
import SwiftData
import Testing
@testable import PaperTrail

@MainActor
@Suite("FilingService rules")
struct FilingServiceRuleTests {
    struct TempLocation: ArchiveLocating {
        let url: URL
        func resolveRoot() async throws -> ArchiveRoot { ArchiveRoot(url: url, isLocalFallback: true) }
    }

    let container: ModelContainer
    let service: FilingService

    init() throws {
        let schema = Schema([DocumentRecord.self, FilingRuleRecord.self])
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = FilingService(location: TempLocation(url: root), store: CoordinatedFileStore())
    }

    func file(owner: String, category: String, iban: String = "") async throws {
        let document = PendingDocument(pdfData: Data("%PDF-1.7 synthetic \(UUID())".utf8), source: .fileImport)
        let request = FilingRequest(owner: owner, category: category, receivedDate: .now, sender: "Praatnet",
                                    description: "Factuur", bill: BillDetails(isUnpaid: !iban.isEmpty, iban: iban))
        _ = try await service.file(document, request: request, extractedText: nil, suggestedSender: "Praatnet Demo", context: container.mainContext)
    }

    @Test func filingLearnsAndUpdatesOneRule() async throws {
        try await file(owner: "Company1", category: "Invoices", iban: "NL00TEST0111222333")
        try await file(owner: "Company2", category: "Letters")

        let rules = try container.mainContext.fetch(FetchDescriptor<FilingRuleRecord>()).map(\.rule)
        #expect(rules.count == 1)
        #expect(rules.first?.owner == "Company2")
        #expect(rules.first?.category == "Letters")
        #expect(rules.first?.aliases == ["praatnet", "praatnet demo"])
        #expect(rules.first?.ibans == ["NL00TEST0111222333"])
    }
}

@MainActor
@Suite("FilingService duplicates")
struct FilingServiceDuplicateTests {
    @Test func findsTheSameFileAndTheSameInvoice() async throws {
        let schema = Schema([DocumentRecord.self, FilingRuleRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = FilingService(location: FilingServiceRuleTests.TempLocation(url: root), store: CoordinatedFileStore())
        let context = container.mainContext

        let bill = BillDetails(isUnpaid: true, amount: 45.99, reference: "BD-778812")
        let request = FilingRequest(owner: "Private", category: "Invoices", receivedDate: .now, sender: "Praatnet", description: "Factuur", bill: bill)
        let scan = PendingDocument(pdfData: Data("%PDF-1.7 synthetic scan".utf8), source: .scan)
        #expect(try service.duplicates(of: scan, request: request, context: context).isEmpty)
        _ = try await service.file(scan, request: request, extractedText: nil, context: context)

        #expect(try service.duplicates(of: scan, request: request, context: context).first?.reason == .sameFile)
        let emailed = PendingDocument(pdfData: Data("%PDF-1.7 synthetic email".utf8), source: .email)
        #expect(try service.duplicates(of: emailed, request: request, context: context).first?.reason == .sameReference)
    }
}

@MainActor
@Suite("Review queue")
struct ReviewQueueTests {
    @Test func savedDocumentWaitsAndLeavesWhenFiled() async throws {
        let schema = Schema([DocumentRecord.self, FilingRuleRecord.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = FilingService(location: FilingServiceRuleTests.TempLocation(url: root), store: CoordinatedFileStore())

        #expect(try await service.reviewQueue.items(root: root).isEmpty)
        let scan = PendingDocument(pdfData: Data("%PDF-1.7 synthetic queued scan".utf8), source: .scan)
        try await service.saveForReview(scan)

        let items = try await service.reviewQueue.items(root: root)
        let item = try #require(items.first)
        #expect(items.count == 1)
        #expect(item.name.hasSuffix(" Scan.pdf"))
        #expect(item.isDownloaded)

        let opened = try await service.reviewQueue.open(item)
        #expect(opened.pdfData == scan.pdfData)
        #expect(opened.reviewItemURL == item.url)
        let request = FilingRequest(owner: "Private", category: "Letters", receivedDate: opened.receivedDate ?? .now, sender: "Gemeente", description: "Brief")
        _ = try await service.file(opened, request: request, extractedText: nil, context: container.mainContext)

        #expect(try await service.reviewQueue.items(root: root).isEmpty)
        await #expect(throws: ReviewQueueError.self) {
            _ = try await service.file(opened, request: request, extractedText: nil, context: container.mainContext)
        }
    }
}

@Suite("InboxCollector")
struct InboxCollectorTests {
    static func pngData() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 40, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func movesPdfsAndImagesAndLeavesOtherFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let inbox = InboxCollector.inbox(in: root)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data("%PDF-1.7 synthetic inbox".utf8).write(to: inbox.appending(path: "factuur.pdf"))
        try Self.pngData().write(to: inbox.appending(path: "bon.png"))
        try Data("notes".utf8).write(to: inbox.appending(path: "notes.txt"))
        try Data("broken".utf8).write(to: inbox.appending(path: "kapot.jpg"))

        let collector = InboxCollector(store: CoordinatedFileStore())
        let report = await collector.collect(root: root)
        #expect(report.moved == 2)
        #expect(report.unsupported == ["notes.txt"])
        #expect(report.failures.count == 1)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: inbox.path(percentEncoded: false)).sorted()
        #expect(remaining == ["kapot.jpg", "notes.txt"])
        let queued = try await ReviewQueue(store: CoordinatedFileStore()).items(root: root).map(\.name)
        #expect(queued.count == 2)
        #expect(queued.contains { $0.hasSuffix(" factuur.pdf") })
        #expect(queued.contains { $0.hasSuffix(" bon.pdf") })
    }
}
