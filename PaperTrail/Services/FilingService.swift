import Foundation
import PaperTrailKit
import SwiftData

/// Files a confirmed document: plan the path, write and verify the PDF, then index it.
struct FilingService {
    var location: any ArchiveLocating
    var store: any ArchiveFileStoring
    var namer = FileNamer()

    func file(_ document: PendingDocument, request: FilingRequest, extractedText: String?, context: ModelContext) async throws -> DocumentRecord {
        let plan = try FilingPlanner.plan(for: request, namer: namer)
        let root = try await location.resolveRoot()
        let stored = try await store.store(document.pdfData, plan: plan, root: root.url, removingSource: nil)

        let record = DocumentRecord(
            relativePath: stored.relativePath,
            ownerName: plan.folderComponents[0],
            categoryName: plan.folderComponents[2],
            sender: namer.cleanSender(request.sender),
            documentDescription: namer.cleanDescription(request.description),
            receivedDate: request.receivedDate,
            documentDate: request.documentDate,
            extractedText: extractedText,
            contentHash: stored.contentHash,
            source: document.source,
            bill: request.bill
        )
        context.insert(record)
        // The file is already safe on disk; an index failure is reported but the index
        // can be rebuilt from the files.
        try context.save()
        return record
    }
}
