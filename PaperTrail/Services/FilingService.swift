import Foundation
import PaperTrailKit
import SwiftData

extension DocumentRecord {
    /// Stores the chosen ledger code with its description as it is now.
    func setLedger(_ ledger: LedgerCode?) {
        ledgerCode = ledger?.code ?? ""
        ledgerDescription = ledger?.description ?? ""
    }
}

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

    /// - Parameter textLayer: For scans, the recognised lines with their place on each page;
    ///   they are added to the PDF as invisible text so the filed file is searchable everywhere.
    func file(_ document: PendingDocument, request: FilingRequest, extractedText: String?, textLayer: [[RecognizedLine]]? = nil,
              suggestedSender: String = "", context: ModelContext) async throws -> DocumentRecord {
        let plan = try FilingPlanner.plan(for: request, namer: namer)
        let root = try await location.resolveRoot()
        if let queued = document.reviewItemURL, !FileManager.default.fileExists(atPath: queued.path(percentEncoded: false)) {
            // Filed or removed elsewhere in the meantime; don't create a second copy.
            throw ReviewQueueError.alreadyHandled(queued.lastPathComponent)
        }
        var pdf = document.pdfData
        if let textLayer {
            let scan = pdf
            // If the layer can't be added (e.g. rotated pages), the scan is filed as it is.
            if let searchable = await Task.detached(operation: { SearchablePDF.addingTextLayer(to: scan, pages: textLayer) }).value {
                pdf = searchable
            }
        }
        let stored = try await store.store(pdf, plan: plan, root: root.url, removingSource: document.reviewItemURL)

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
        record.vatInfo = request.vat
        record.setLedger(request.ledger)
        record.ibanUnconfirmed = request.ibanChanged && !request.ibanConfirmed && request.bill?.isUnpaid == true
        context.insert(record)
        learnRule(from: record, request: request, suggestedSender: suggestedSender, context: context)
        // The file is already safe on disk; an index failure is reported but the index
        // can be rebuilt from the files.
        try context.save()
        return record
    }

    /// Saves changed details of a filed document. The file is moved or renamed first when its
    /// owner, category, received date, sender or description changed; then the index follows.
    /// The correction also updates the learned rule for the sender, with the old name as alias.
    func update(_ record: DocumentRecord, request: FilingRequest, context: ModelContext) async throws {
        let plan = try FilingPlanner.plan(for: request, namer: namer)
        if !DocumentEdit.isAlreadyAt(record.relativePath, plan: plan) {
            let root = try await location.resolveRoot()
            record.relativePath = try await store.move(record.relativePath, to: plan, root: root.url)
        }
        let previousSender = record.sender
        record.ownerName = plan.folderComponents[0]
        record.categoryName = plan.folderComponents[2]
        record.sender = namer.cleanSender(request.sender)
        record.documentDescription = namer.cleanDescription(request.description)
        record.receivedDate = request.receivedDate
        record.documentDate = request.documentDate
        let bill = request.bill ?? BillDetails()
        record.isUnpaidBill = bill.isUnpaid
        record.amount = bill.amount
        record.dueDate = bill.dueDate
        record.iban = bill.iban.isEmpty ? nil : bill.iban
        record.paymentReference = bill.reference.isEmpty ? nil : bill.reference
        record.reimbursedBy = request.reimbursedBy
        record.vatInfo = request.vat
        record.setLedger(request.ledger)
        record.ibanUnconfirmed = request.ibanChanged && !request.ibanConfirmed && request.bill?.isUnpaid == true
        if let learned = learnRule(from: record, request: request, suggestedSender: previousSender, context: context),
           previousSender.lowercased() != record.sender.lowercased() {
            forgetOldName(previousSender, keeping: learned, context: context)
        }
        try context.save()
    }

    /// Other rules stop matching the sender's old (wrong) name; empty rules are removed.
    private func forgetOldName(_ name: String, keeping kept: UUID, context: ModelContext) {
        let records = (try? context.fetch(FetchDescriptor<FilingRuleRecord>())) ?? []
        for changed in SenderRules.releasing(oldName: name, keeping: kept, in: records.map(\.rule)) {
            guard let record = records.first(where: { $0.id == changed.id }) else { continue }
            if changed.aliases.isEmpty { context.delete(record) } else { record.update(from: changed) }
        }
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
    @discardableResult
    private func learnRule(from record: DocumentRecord, request: FilingRequest, suggestedSender: String, context: ModelContext) -> UUID? {
        // A failed fetch only means no rule is learned this time; filing itself is unaffected.
        let records = (try? context.fetch(FetchDescriptor<FilingRuleRecord>())) ?? []
        let payTo = request.bill?.isUnpaid == true ? request.bill?.iban ?? "" : ""
        var filing = ConfirmedFiling(
            sender: record.sender, suggestedSender: suggestedSender,
            owner: record.ownerName, category: record.categoryName, payToIban: payTo,
            reimbursedBy: request.reimbursedBy,
            ledgerCode: request.offersLedgerCodes ? request.ledger?.code ?? "" : nil
        )
        filing.ibanConfirmed = request.ibanConfirmed
        guard let rule = SenderRules.learn(from: filing, existing: records.map(\.rule)) else { return nil }
        if let existing = records.first(where: { $0.id == rule.id }) {
            existing.update(from: rule)
        } else {
            context.insert(FilingRuleRecord(rule))
        }
        return rule.id
    }
}
