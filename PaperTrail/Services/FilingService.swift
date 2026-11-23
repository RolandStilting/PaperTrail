import Foundation
import PaperTrailKit
import SwiftData

/// Files a confirmed document: plan the path, write and verify the PDF, then index it.
struct FilingService {
    var location: any ArchiveLocating
    var store: any ArchiveFileStoring
    var namer = FileNamer()

    var reviewQueue: ReviewQueue { ReviewQueue(store: store) }
    var inboxCollector: InboxCollector { InboxCollector(store: store) }

    /// Saves the document to Needs Review to file later.
    func saveForReview(_ document: PendingDocument) async throws {
        let root = try await location.resolveRoot()
        _ = try await reviewQueue.add(document, root: root.url)
    }

    func file(_ document: PendingDocument, request: FilingRequest, extractedText: String?, suggestedSender: String = "", context: ModelContext) async throws -> DocumentRecord {
        let plan = try FilingPlanner.plan(for: request, namer: namer)
        let root = try await location.resolveRoot()
        if let queued = document.reviewItemURL, !FileManager.default.fileExists(atPath: queued.path(percentEncoded: false)) {
            // Filed or removed elsewhere in the meantime; don't create a second copy.
            throw ReviewQueueError.alreadyHandled(queued.lastPathComponent)
        }
        let stored = try await store.store(document.pdfData, plan: plan, root: root.url, removingSource: document.reviewItemURL)

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
        record.reimbursedBy = request.reimbursedBy
        context.insert(record)
        learnRule(from: record, request: request, suggestedSender: suggestedSender, context: context)
        // The file is already safe on disk; an index failure is reported but the index
        // can be rebuilt from the files.
        try context.save()
        return record
    }

    /// Documents already in the index that look like this one. Only warns; the user decides.
    func duplicates(of document: PendingDocument, request: FilingRequest, context: ModelContext) throws -> [DuplicateMatch] {
        let candidate = DuplicateFacts(
            contentHash: CoordinatedFileStore.sha256(document.pdfData),
            sender: namer.cleanSender(request.sender),
            amount: request.bill?.amount,
            reference: request.bill?.reference,
            documentDate: request.documentDate,
            receivedDate: request.receivedDate
        )
        let records = try context.fetch(FetchDescriptor<DocumentRecord>())
        return DuplicateDetector.matches(for: candidate, in: records.map(\.duplicateFacts), calendar: namer.calendar)
    }

    /// Remembers owner and category for this sender, so the next document from them is
    /// filed the same way. Saved together with the record.
    private func learnRule(from record: DocumentRecord, request: FilingRequest, suggestedSender: String, context: ModelContext) {
        // A failed fetch only means no rule is learned this time; filing itself is unaffected.
        let records = (try? context.fetch(FetchDescriptor<FilingRuleRecord>())) ?? []
        let payTo = request.bill?.isUnpaid == true ? request.bill?.iban ?? "" : ""
        let filing = ConfirmedFiling(
            sender: record.sender, suggestedSender: suggestedSender,
            owner: record.ownerName, category: record.categoryName, payToIban: payTo,
            reimbursedBy: request.reimbursedBy
        )
        guard let rule = SenderRules.learn(from: filing, existing: records.map(\.rule)) else { return }
        if let existing = records.first(where: { $0.id == rule.id }) {
            existing.update(from: rule)
        } else {
            context.insert(FilingRuleRecord(rule))
        }
    }
}
