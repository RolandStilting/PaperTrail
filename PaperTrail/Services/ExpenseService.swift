import Foundation
import PaperTrailKit
import SwiftData

nonisolated enum ExpenseClaimError: LocalizedError {
    case receiptMissing(String)
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .receiptMissing(let path):
            String(localized: "The receipt \"\(path)\" is not in Paper Trail anymore (moved or renamed?). Put it back or remove it from the claim, then try again.")
        case .nothingSelected:
            String(localized: "Select at least one expense for the claim.")
        }
    }
}

/// The files of one claim, ready to share.
struct ClaimPackage: Identifiable {
    var id: UUID { claimID }
    var claimID: UUID
    var pdf: URL
    var csv: URL
}

/// Creates expense claims, and marks them reimbursed or undoes them.
struct ExpenseService {
    var location: any ArchiveLocating

    /// Builds the PDF and CSV, then records the claim. Nothing is recorded if a receipt can't be read.
    /// - Parameter vatCodes: The company's input VAT ledger codes, shown with the VAT per receipt.
    func createClaim(company: String, expenses: [DocumentRecord], vatCodes: [VATLedgerCode] = [], context: ModelContext,
                     now: Date = .now) async throws -> ClaimPackage {
        guard !expenses.isEmpty else { throw ExpenseClaimError.nothingSelected }
        let sorted = Self.sorted(expenses)
        let claim = ExpenseClaimRecord(ownerName: company, createdAt: now, expenseCount: sorted.count,
                                       total: ExpenseClaim.total(sorted.map { Self.line($0) }))
        let package = try await files(for: claim, expenses: sorted, vatCodes: vatCodes)
        context.insert(claim)
        for expense in sorted { expense.claimID = claim.id }
        try context.save()
        return package
    }

    /// The claim's files again, e.g. to send them a second time.
    func files(for claim: ExpenseClaimRecord, expenses: [DocumentRecord], vatCodes: [VATLedgerCode] = []) async throws -> ClaimPackage {
        let sorted = Self.sorted(expenses)
        let root = try await location.resolveRoot().url
        var receipts: [Data] = []
        for expense in sorted {
            let url = root.appending(path: expense.relativePath)
            do {
                receipts.append(try InboxCollector.coordinatedRead(url))
            } catch {
                throw ExpenseClaimError.receiptMissing(expense.relativePath)
            }
        }
        let date = claim.createdAt.formatted(.iso8601.year().month().day())
        let title = String(localized: "Expense claim \(claim.ownerName)")
        let subtitle = String(localized: "\(sorted.count) expenses, created \(claim.createdAt.formatted(date: .long, time: .omitted))")
        let lines = sorted.map { Self.line($0, vatCodes: vatCodes) }
        let pdf = try ExpenseClaim.pdf(title: title, subtitle: subtitle, lines: lines, receipts: receipts)
        let csv = ExpenseClaim.csv(lines, vatCodes: vatCodes)

        let folder = FileManager.default.temporaryDirectory.appending(path: "\(TemporaryFiles.claimsFolder)/\(claim.id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = FileNamer.sanitizeComponent("\(title) \(date)")
        let pdfURL = folder.appending(path: "\(base).pdf")
        let csvURL = folder.appending(path: "\(base).csv")
        try pdf.write(to: pdfURL, options: .atomic)
        try csv.write(to: csvURL, options: .atomic)
        return ClaimPackage(claimID: claim.id, pdf: pdfURL, csv: csvURL)
    }

    /// The company paid: the claim and all its expenses are done at once.
    func markReimbursed(_ claim: ExpenseClaimRecord, expenses: [DocumentRecord], context: ModelContext, now: Date = .now) throws {
        claim.reimbursedAt = now
        for expense in expenses where expense.claimID == claim.id { expense.reimbursedAt = now }
        try context.save()
    }

    /// Undoes "Mark Reimbursed": the claim and its expenses are submitted again.
    func markNotReimbursed(_ claim: ExpenseClaimRecord, expenses: [DocumentRecord], context: ModelContext) throws {
        claim.reimbursedAt = nil
        for expense in expenses where expense.claimID == claim.id { expense.reimbursedAt = nil }
        try context.save()
    }

    /// Takes the claim back: its expenses are open again.
    func undo(_ claim: ExpenseClaimRecord, expenses: [DocumentRecord], context: ModelContext) throws {
        for expense in expenses where expense.claimID == claim.id {
            expense.claimID = nil
            expense.reimbursedAt = nil
        }
        context.delete(claim)
        try context.save()
    }

    static func line(_ expense: DocumentRecord, vatCodes: [VATLedgerCode] = []) -> ClaimLine {
        ClaimLine(date: expense.documentDate ?? expense.receivedDate, sender: expense.sender,
                  description: expense.documentDescription, amount: expense.amount, relativePath: expense.relativePath,
                  ledgerCode: expense.ledgerCode, ledgerDescription: expense.ledgerDescription,
                  vat: ClaimVATLine.reclaimable(expense.vatInfo, codes: vatCodes))
    }

    static func sorted(_ expenses: [DocumentRecord]) -> [DocumentRecord] {
        expenses.sorted { ($0.documentDate ?? $0.receivedDate) < ($1.documentDate ?? $1.receivedDate) }
    }
}
