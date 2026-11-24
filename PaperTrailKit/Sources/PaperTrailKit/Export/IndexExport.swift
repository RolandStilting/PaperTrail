import Foundation

/// Everything Paper Trail knows beyond the PDFs themselves, as plain data: what's needed to
/// rebuild the index, and to keep the bookkeeping if the app is ever gone. Written as JSON
/// (complete, for import) and CSV (documents only, for Excel or Numbers) next to the archive.
public struct IndexExport: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var format = "Paper Trail index"
    public var version = IndexExport.currentVersion
    public var exportedAt: Date
    public var documents: [Document]
    public var expenseClaims: [ExpenseClaim]
    public var vatReturns: [VATReturn]
    public var senderRules: [Rule]
    /// Owners, categories and payment settings at export time. For reference; import leaves
    /// the current settings alone (they sync through iCloud on their own).
    public var settings: ArchiveSettings?

    public init(exportedAt: Date, documents: [Document], expenseClaims: [ExpenseClaim], vatReturns: [VATReturn],
                senderRules: [Rule], settings: ArchiveSettings?) {
        self.exportedAt = exportedAt
        self.documents = documents
        self.expenseClaims = expenseClaims
        self.vatReturns = vatReturns
        self.senderRules = senderRules
        self.settings = settings
    }

    public struct Document: Codable, Sendable, Equatable {
        public var id: UUID
        /// Path below the "Paper Trail" folder in iCloud Drive.
        public var relativePath: String
        public var owner: String
        public var category: String
        public var sender: String
        public var description: String
        public var receivedDate: Date
        public var documentDate: Date?
        public var filedAt: Date
        public var source: String
        public var contentHash: String?
        public var isUnpaidBill: Bool
        public var amount: Double?
        public var dueDate: Date?
        public var iban: String?
        public var paymentReference: String?
        public var isPaid: Bool
        public var paidAt: Date?
        public var reminderID: String?
        public var exportedToSEPAAt: Date?
        public var reimbursedBy: String?
        public var claimID: UUID?
        public var reimbursedAt: Date?
        public var vat: VATInfo?
        public var paymentCode: PaymentCode?
        public var recognizedText: String?
    }

    public struct ExpenseClaim: Codable, Sendable, Equatable {
        public var id: UUID
        public var company: String
        public var createdAt: Date
        public var reimbursedAt: Date?
        public var expenseCount: Int
        public var total: Double
    }

    public struct VATReturn: Codable, Sendable, Equatable {
        public var id: UUID
        public var owner: String
        public var periodStart: Date
        public var periodEnd: Date
        public var submittedAt: Date
        public var vatTotal: Double
        public var documentCount: Int
    }

    public struct Rule: Codable, Sendable, Equatable {
        public var id: UUID
        public var senderName: String
        public var aliases: [String]
        public var ibans: [String]
        public var owner: String
        public var category: String
        public var reimbursedBy: String?
        public var updatedAt: Date
    }

    // MARK: JSON

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ISO 8601 with milliseconds, readable by people and spreadsheets.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.dateStyle))
        }
        return try encoder.encode(self)
    }

    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public enum ReadError: LocalizedError, Equatable {
        case notAnExport
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notAnExport:
                String(localized: "This file is not a Paper Trail index export. Choose \"Paper Trail Index.json\" from the Export folder.", bundle: .module)
            case .newerVersion:
                String(localized: "This export was made by a newer version of Paper Trail. Update the app, then import it again.", bundle: .module)
            }
        }
    }

    public static func read(_ data: Data) throws(ReadError) -> IndexExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? dateStyle.parse(text) ?? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
        }
        guard let export = try? decoder.decode(IndexExport.self, from: data), export.format == "Paper Trail index" else {
            throw .notAnExport
        }
        guard export.version <= currentVersion else { throw .newerVersion(export.version) }
        return export
    }

    // MARK: CSV

    /// One row per document. Semicolon-separated with a UTF-8 byte order mark, so Excel in
    /// Dutch settings opens it in columns; amounts use the locale's decimal separator.
    public func documentsCSV(locale: Locale = .current, calendar: Calendar? = nil) -> Data {
        let namer = FileNamer(calendar: calendar ?? FileNamer.defaultCalendar())
        let decimal = locale.decimalSeparator ?? ","
        func amount(_ value: Double?) -> String {
            guard let value else { return "" }
            return String(format: "%.2f", value).replacingOccurrences(of: ".", with: decimal)
        }
        func date(_ value: Date?) -> String { value.map(namer.dateString) ?? "" }
        func field(_ text: String) -> String {
            let needsQuotes = text.contains(";") || text.contains("\"") || text.contains("\n") || text.contains("\r")
            return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        func vat(_ info: VATInfo?, rate: Double) -> String {
            guard let lines = info?.lines.filter({ abs($0.rate - rate) < 0.001 }), !lines.isEmpty else { return "" }
            return amount(lines.map(\.amount).reduce(0, +))
        }
        let yes = String(localized: "yes", bundle: .module)
        var rows = [[
            "Received", "Document date", "Owner", "Category", "Sender", "Description", "Amount (EUR)",
            "VAT 21%", "VAT 9%", "VAT 0%", "VAT total", "Foreign VAT", "Reverse charge",
            "Unpaid bill", "Due date", "Paid", "Paid on", "IBAN", "Payment reference",
            "Reimbursed by", "Reimbursed on", "File", "ID",
        ].map { String(localized: String.LocalizationValue($0), bundle: .module) }]
        for document in documents.sorted(by: { ($0.receivedDate, $0.relativePath) < ($1.receivedDate, $1.relativePath) }) {
            rows.append([
                date(document.receivedDate), date(document.documentDate), document.owner, document.category,
                document.sender, document.description, amount(document.amount),
                vat(document.vat, rate: 21), vat(document.vat, rate: 9), vat(document.vat, rate: 0),
                document.vat.map { amount($0.total) } ?? "",
                document.vat?.isForeign == true ? yes : "", document.vat?.isReverseCharge == true ? yes : "",
                document.isUnpaidBill ? yes : "", date(document.dueDate), document.isPaid ? yes : "", date(document.paidAt),
                document.iban ?? "", document.paymentReference ?? "",
                document.reimbursedBy ?? "", date(document.reimbursedAt), document.relativePath, document.id.uuidString,
            ])
        }
        let text = rows.map { $0.map(field).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }
}

// MARK: From and to the index

extension DocumentRecord {
    public var exported: IndexExport.Document {
        IndexExport.Document(
            id: id, relativePath: relativePath, owner: ownerName, category: categoryName, sender: sender,
            description: documentDescription, receivedDate: receivedDate, documentDate: documentDate, filedAt: filedAt,
            source: sourceRaw, contentHash: contentHash, isUnpaidBill: isUnpaidBill, amount: amount, dueDate: dueDate,
            iban: iban, paymentReference: paymentReference, isPaid: isPaid, paidAt: paidAt, reminderID: reminderExternalID,
            exportedToSEPAAt: exportedAt, reimbursedBy: reimbursedBy, claimID: claimID, reimbursedAt: reimbursedAt,
            vat: vatInfo, paymentCode: paymentCode, recognizedText: extractedText
        )
    }

    /// A new index record for an exported document.
    public convenience init(imported document: IndexExport.Document) {
        self.init(relativePath: document.relativePath, ownerName: document.owner, categoryName: document.category,
                  sender: document.sender, documentDescription: document.description, receivedDate: document.receivedDate,
                  documentDate: document.documentDate, extractedText: document.recognizedText, contentHash: document.contentHash,
                  filedAt: document.filedAt, source: IntakeSource(rawValue: document.source) ?? .scan)
        id = document.id
        isUnpaidBill = document.isUnpaidBill
        amount = document.amount
        dueDate = document.dueDate
        iban = document.iban
        paymentReference = document.paymentReference
        isPaid = document.isPaid
        paidAt = document.paidAt
        reminderExternalID = document.reminderID
        exportedAt = document.exportedToSEPAAt
        reimbursedBy = document.reimbursedBy
        claimID = document.claimID
        reimbursedAt = document.reimbursedAt
        vatInfo = document.vat
        paymentCode = document.paymentCode
    }
}

extension ExpenseClaimRecord {
    public var exported: IndexExport.ExpenseClaim {
        .init(id: id, company: ownerName, createdAt: createdAt, reimbursedAt: reimbursedAt, expenseCount: expenseCount, total: total)
    }

    public convenience init(imported claim: IndexExport.ExpenseClaim) {
        self.init(id: claim.id, ownerName: claim.company, createdAt: claim.createdAt, expenseCount: claim.expenseCount, total: claim.total)
        reimbursedAt = claim.reimbursedAt
    }
}

extension VATReturnRecord {
    public var exported: IndexExport.VATReturn {
        .init(id: id, owner: ownerName, periodStart: periodStart, periodEnd: periodEnd, submittedAt: submittedAt,
              vatTotal: vatTotal, documentCount: documentCount)
    }

    public convenience init(imported vatReturn: IndexExport.VATReturn) {
        self.init(ownerName: vatReturn.owner, period: VATPeriod(kind: .quarter, start: vatReturn.periodStart, end: vatReturn.periodEnd),
                  submittedAt: vatReturn.submittedAt, vatTotal: vatReturn.vatTotal, documentCount: vatReturn.documentCount)
        id = vatReturn.id
    }
}

extension IndexExport.Rule {
    public init(_ rule: SenderRule) {
        self.init(id: rule.id, senderName: rule.senderName, aliases: rule.aliases, ibans: rule.ibans, owner: rule.owner,
                  category: rule.category, reimbursedBy: rule.reimbursedBy, updatedAt: rule.updatedAt)
    }

    public var rule: SenderRule {
        SenderRule(id: id, senderName: senderName, aliases: aliases, ibans: ibans, owner: owner, category: category,
                   reimbursedBy: reimbursedBy, updatedAt: updatedAt)
    }
}

// MARK: Import

/// What importing an export adds. Import only adds what's missing; it never changes or
/// removes anything already in the index, so it is safe to run more than once.
public struct IndexImportPlan: Sendable, Equatable {
    public var documents: [IndexExport.Document] = []
    public var expenseClaims: [IndexExport.ExpenseClaim] = []
    public var vatReturns: [IndexExport.VATReturn] = []
    public var senderRules: [IndexExport.Rule] = []
    /// Already in the index (same ID or same file).
    public var documentsAlreadyThere = 0
    /// In the export, but their PDF is no longer in iCloud Drive; not added.
    public var missingFiles: [String] = []

    public var isEmpty: Bool { documents.isEmpty && expenseClaims.isEmpty && vatReturns.isEmpty && senderRules.isEmpty }

    public init(export: IndexExport, documentIDs: Set<UUID>, documentPaths: Set<String>, claimIDs: Set<UUID>,
                vatReturns existingReturns: [(owner: String, start: Date)], ruleIDs: Set<UUID>, fileExists: (String) -> Bool) {
        let paths = Set(documentPaths.map { $0.lowercased() })
        for document in export.documents {
            if documentIDs.contains(document.id) || paths.contains(document.relativePath.lowercased()) {
                documentsAlreadyThere += 1
            } else if !fileExists(document.relativePath) {
                missingFiles.append(document.relativePath)
            } else {
                documents.append(document)
            }
        }
        expenseClaims = export.expenseClaims.filter { !claimIDs.contains($0.id) }
        // A period marked submitted again on another device has a new ID; one per owner and period.
        vatReturns = export.vatReturns.filter { vatReturn in
            !existingReturns.contains { $0.owner == vatReturn.owner && $0.start == vatReturn.periodStart }
        }
        senderRules = export.senderRules.filter { !ruleIDs.contains($0.id) }
    }
}
