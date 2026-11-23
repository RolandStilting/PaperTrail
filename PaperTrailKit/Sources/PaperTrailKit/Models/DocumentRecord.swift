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

public enum IntakeSource: String, Codable, Sendable, CaseIterable {
    case scan
    case fileImport
    case share
    case inboxFolder
    case email
}
