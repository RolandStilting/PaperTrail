import Foundation
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
