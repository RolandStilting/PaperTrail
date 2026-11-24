import Foundation
import Testing
@testable import PaperTrailKit

/// Synthetic data only (invented senders, test IBAN).
@Suite("IndexExport")
struct IndexExportTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }()

    func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day))! }

    func bill() -> DocumentRecord {
        let record = DocumentRecord(relativePath: "Company1/2026/Invoices/2026-11-23 Voorbeeld Energie - Nota.pdf", ownerName: "Company1",
                                    categoryName: "Invoices", sender: "Voorbeeld Energie", documentDescription: "Nota; november",
                                    receivedDate: date(23), documentDate: date(20), extractedText: "Voorbeeld Energie nota", source: .email,
                                    bill: BillDetails(isUnpaid: true, amount: 121, dueDate: date(30), iban: "NL00TEST0123456789", reference: "TEST-1"))
        record.vatInfo = VATInfo(lines: [VATLine(rate: 21, base: 100, amount: 21)])
        record.reminderExternalID = "reminder-1"
        // Exported times keep milliseconds; whole seconds compare exactly.
        record.filedAt = date(23).addingTimeInterval(36_000.25)
        record.paymentCode = PaymentCode(source: .link, payload: "https://pay.example.test/1")
        return record
    }

    func export(_ documents: [DocumentRecord]) -> IndexExport {
        IndexExport(exportedAt: date(24), documents: documents.map(\.exported),
                    expenseClaims: [ExpenseClaimRecord(ownerName: "Company1", createdAt: date(10), expenseCount: 2, total: 30).exported],
                    vatReturns: [], senderRules: [IndexExport.Rule(SenderRule(senderName: "Voorbeeld Energie", aliases: ["voorbeeld energie"],
                                                                               owner: "Company1", category: "Invoices", updatedAt: date(23)))],
                    settings: .defaults)
    }

    @Test func jsonRoundTripKeepsEverything() throws {
        let original = bill()
        let export = export([original])
        let read = try IndexExport.read(try export.json())
        #expect(read == export)

        let restored = DocumentRecord(imported: read.documents[0])
        #expect(restored.id == original.id)
        #expect(restored.exported == original.exported)
        #expect(restored.vatInfo?.total == 21)
        #expect(restored.reminderExternalID == "reminder-1")
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: IndexExport.ReadError.notAnExport) { try IndexExport.read(Data("{\"hello\": 1}".utf8)) }
        var newer = export([])
        newer.version = 99
        #expect(throws: IndexExport.ReadError.newerVersion(99)) { try IndexExport.read(try newer.json()) }
    }

    @Test func csvHasOneRowPerDocument() throws {
        let csv = export([bill()]).documentsCSV(locale: Locale(identifier: "nl_NL"), calendar: calendar)
        let text = try #require(String(data: csv.dropFirst(3), encoding: .utf8))
        let rows = text.split(separator: "\r\n")
        #expect(rows.count == 2)
        #expect(rows[1].contains("2026-11-23;2026-11-20;Company1;Invoices;Voorbeeld Energie;\"Nota; november\";121,00;21,00"))
        #expect(rows[1].contains("NL00TEST0123456789"))
    }

    @Test func importAddsOnlyWhatIsMissing() {
        let kept = bill()
        let lost = bill()
        lost.relativePath = "Company1/2026/Invoices/2026-11-23 Voorbeeld Energie - Andere nota.pdf"
        let gone = bill()
        gone.relativePath = "Company1/2026/Invoices/weg.pdf"
        let export = export([kept, lost, gone])

        let plan = IndexImportPlan(export: export, documentIDs: [kept.id], documentPaths: [kept.relativePath], claimIDs: [],
                                   vatReturns: [], ruleIDs: [], fileExists: { $0 != gone.relativePath })
        #expect(plan.documents.map(\.id) == [lost.id])
        #expect(plan.documentsAlreadyThere == 1)
        #expect(plan.missingFiles == [gone.relativePath])
        #expect(plan.expenseClaims.count == 1)
        #expect(plan.senderRules.count == 1)

        // Running it again after importing adds nothing.
        let again = IndexImportPlan(export: export, documentIDs: [kept.id, lost.id], documentPaths: [], claimIDs: Set(export.expenseClaims.map(\.id)),
                                    vatReturns: [], ruleIDs: Set(export.senderRules.map(\.id)), fileExists: { $0 != gone.relativePath })
        #expect(again.isEmpty)
    }

    @Test func vatReturnMatchedByOwnerAndPeriod() {
        var export = export([])
        export.vatReturns = [IndexExport.VATReturn(id: UUID(), owner: "Company1", periodStart: date(1), periodEnd: date(30), submittedAt: date(24), vatTotal: 21, documentCount: 1)]
        let plan = IndexImportPlan(export: export, documentIDs: [], documentPaths: [], claimIDs: [],
                                   vatReturns: [(owner: "Company1", start: date(1))], ruleIDs: [], fileExists: { _ in true })
        #expect(plan.vatReturns.isEmpty)
    }
}
