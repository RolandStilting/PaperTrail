import Foundation
import SwiftData

/// Index entry for one filed document.
///
/// The PDF in iCloud Drive is the source of truth; this record holds extra metadata
/// and must be rebuildable from the files. CloudKit sync requires every property to be
/// optional or have a default value, and forbids unique constraints.
@Model
public final class DocumentRecord {
    public var id: UUID = UUID()
    /// Path relative to the archive root, e.g. "Private/2026/Invoices/2026-03-01 KPN - Mobile invoice March.pdf".
    public var relativePath: String = ""
    public var ownerName: String = ""
    public var categoryName: String = ""
    public var sender: String = ""
    public var documentDescription: String = ""
    /// Date the document was received; drives the file name and year folder.
    public var receivedDate: Date = Date.distantPast
    /// Date printed on the document, if known. Stored separately from the received date.
    public var documentDate: Date?
    /// OCR or embedded PDF text. Never log this outside debug builds.
    public var extractedText: String?
    /// SHA-256 of the PDF bytes, hex encoded. Used for duplicate checks in phase 2.
    public var contentHash: String?
    public var filedAt: Date = Date.distantPast
    /// How the document came in, e.g. "scan" or "import". See `IntakeSource`.
    public var sourceRaw: String = IntakeSource.scan.rawValue

    // Bill details (phase 2). Phase 4 turns unpaid bills into reminders.
    public var isUnpaidBill: Bool = false
    /// Amount in euros.
    public var amount: Double?
    public var dueDate: Date?
    /// IBAN to pay to, without spaces.
    public var iban: String?
    public var paymentReference: String?

    // Paying (phase 4). Paid = the reminder was completed (or "Mark as paid" in the app).
    public var isPaid: Bool = false
    public var paidAt: Date?
    /// Reminders' calendarItemExternalIdentifier; the same on all devices for iCloud reminders.
    public var reminderExternalID: String?
    /// When the bill was last put in a SEPA batch file. Exported is not paid.
    public var exportedAt: Date?

    // Expense claims (phase 6): a document one company pays back, e.g. a personal receipt.
    /// Owner (company) that reimburses this expense; nil when it isn't a claimable expense.
    public var reimbursedBy: String?
    /// The claim it was submitted in; nil while the expense is still open.
    public var claimID: UUID?
    public var reimbursedAt: Date?

    public var claimState: ClaimState {
        guard reimbursedBy != nil else { return .none }
        if reimbursedAt != nil { return .reimbursed }
        return claimID == nil ? .open : .submitted
    }

    // VAT (phase 7), stored as VATInfo JSON; empty when unknown or not relevant.
    public var vatInfoText: String = ""

    public var vatInfo: VATInfo? {
        get { VATInfo.decode(vatInfoText) }
        set { vatInfoText = newValue?.encoded ?? "" }
    }

    // Payment code on the document itself (iDEAL/Tikkie QR or a pay link), as PaymentCode JSON.
    public var paymentCodeText: String = ""
    /// When the document was searched for a payment code; nil = not yet.
    public var paymentCodeCheckedAt: Date?

    public var paymentCode: PaymentCode? {
        get { PaymentCode.decode(paymentCodeText) }
        set { paymentCodeText = newValue?.encoded ?? "" }
    }

    /// The date that decides the VAT period: the date on the document, else the received date.
    public var vatDate: Date { documentDate ?? receivedDate }

    /// Unpaid bill still waiting for payment.
    public var isOpenBill: Bool { isUnpaidBill && !isPaid }

    /// Link from the reminder back into the app.
    public var billURL: URL { URL(string: "papertrail://bill/\(id.uuidString)")! }

    public init(
        relativePath: String,
        ownerName: String,
        categoryName: String,
        sender: String,
        documentDescription: String,
        receivedDate: Date,
        documentDate: Date? = nil,
        extractedText: String? = nil,
        contentHash: String? = nil,
        filedAt: Date = .now,
        source: IntakeSource,
        bill: BillDetails? = nil
    ) {
        self.relativePath = relativePath
        self.ownerName = ownerName
        self.categoryName = categoryName
        self.sender = sender
        self.documentDescription = documentDescription
        self.receivedDate = receivedDate
        self.documentDate = documentDate
        self.extractedText = extractedText
        self.contentHash = contentHash
        self.filedAt = filedAt
        self.sourceRaw = source.rawValue
        if let bill, !bill.isEmpty {
            self.isUnpaidBill = bill.isUnpaid
            self.amount = bill.amount
            self.dueDate = bill.dueDate
            self.iban = bill.iban.isEmpty ? nil : bill.iban
            self.paymentReference = bill.reference.isEmpty ? nil : bill.reference
        }
    }

    public var source: IntakeSource {
        IntakeSource(rawValue: sourceRaw) ?? .scan
    }
}

public enum ClaimState: String, Sendable {
    case none, open, submitted, reimbursed
}

public enum IntakeSource: String, Codable, Sendable, CaseIterable {
    case scan
    case fileImport
    case share
    case inboxFolder
    case email
}
