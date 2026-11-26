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
        record.ledgerCode = "4300"
        record.ledgerDescription = "Energie"
        return record
    }

    func export(_ documents: [DocumentRecord]) -> IndexExport {
        IndexExport(exportedAt: date(24), documents: documents.map(\.exported),
                    expenseClaims: [ExpenseClaimRecord(ownerName: "Company1", createdAt: date(10), expenseCount: 2, total: 30).exported],
                    vatReturns: [], senderRules: [IndexExport.Rule(SenderRule(senderName: "Voorbeeld Energie", aliases: ["voorbeeld energie"],
                                                                               owner: "Company1", category: "Invoices",
                                                                               ledgerCodes: [LedgerChoice(owner: "Company1", code: "4300")],
                                                                               updatedAt: date(23)))],
                    settings: ArchiveSettings(owners: [Owner(name: "Company1", vatPeriod: .quarter, vatLedgerCodes: [VATLedgerCode(rate: 21, code: "1510")]),
                                                       Owner(name: "Private")],
                                              categories: ArchiveSettings.defaults.categories))
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
        #expect(restored.ledgerCode == "4300")
        #expect(restored.ledgerDescription == "Energie")
        #expect(read.senderRules[0].rule.ledgerCode(owner: "Company1") == "4300")
    }

    @Test func readsExportsMadeBeforeLedgerCodes() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: try export([bill()]).json()) as? [String: Any])
        var documents = try #require(json["documents"] as? [[String: Any]])
        documents[0]["ledgerCode"] = nil
        documents[0]["ledgerDescription"] = nil
        json["documents"] = documents
        var rules = try #require(json["senderRules"] as? [[String: Any]])
        rules[0]["ledgerCodes"] = nil
        json["senderRules"] = rules
        let read = try IndexExport.read(try JSONSerialization.data(withJSONObject: json))
        #expect(read.documents[0].ledgerCode == nil)
        #expect(DocumentRecord(imported: read.documents[0]).ledgerCode == "")
        #expect(read.senderRules[0].rule.ledgerCodes.isEmpty)
    }

    @Test func readsDatesWithAndWithoutMilliseconds() throws {
        let json = try String(decoding: export([bill()]).json(), as: UTF8.self)
        // Strip the milliseconds from every date, as a hand-edited file might have them.
        let plain = json.replacingOccurrences(of: #"\.\d{3}Z"#, with: "Z", options: .regularExpression)
        #expect(plain != json)
        let read = try IndexExport.read(Data(plain.utf8))
        #expect(read.documents.first?.receivedDate == date(23))
        #expect(read.exportedAt == date(24))
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
        #expect(rows[1].contains("2026-11-23;2026-11-20;Company1;Invoices;4300;Energie;Voorbeeld Energie;\"Nota; november\";121,00;21,00"))
        #expect(rows[1].contains("NL00TEST0123456789"))
        #expect(rows[1].contains(";21,00;1510;;"))
        #expect(rows[0].contains("VAT total;VAT 21% ledger code;VAT 9% ledger code;"))
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

    @Test func importSkipsPathsOutsideTheArchive() {
        let outside = bill()
        outside.relativePath = "../../Library/Keychains/x.pdf"
        var looked: [String] = []
        let plan = IndexImportPlan(export: export([outside]), documentIDs: [], documentPaths: [], claimIDs: [],
                                   vatReturns: [], ruleIDs: [], fileExists: { looked.append($0); return true })
        #expect(plan.documents.isEmpty)
        #expect(plan.unsafePaths == [outside.relativePath])
        #expect(looked.isEmpty)
    }

    @Test func vatReturnMatchedByOwnerAndPeriod() {
        var export = export([])
        export.vatReturns = [IndexExport.VATReturn(id: UUID(), owner: "Company1", periodStart: date(1), periodEnd: date(30), submittedAt: date(24), vatTotal: 21, documentCount: 1)]
        let plan = IndexImportPlan(export: export, documentIDs: [], documentPaths: [], claimIDs: [],
                                   vatReturns: [(owner: "Company1", start: date(1))], ruleIDs: [], fileExists: { _ in true })
        #expect(plan.vatReturns.isEmpty)
    }
}
