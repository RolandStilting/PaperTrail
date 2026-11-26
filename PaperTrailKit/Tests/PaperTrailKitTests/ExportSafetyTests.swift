import Foundation
import Testing
@testable import PaperTrailKit

/// Text chosen by a document's sender must stay text: in CSV files, import paths and QR codes.
/// Synthetic data only.
@Suite("Export safety")
struct ExportSafetyTests {
    @Test func formulasBecomeText() {
        #expect(CSVField.escape("=HYPERLINK(\"https://evil.example.test\")") == "\"'=HYPERLINK(\"\"https://evil.example.test\"\")\"")
        #expect(CSVField.escape("+31 20 123") == "'+31 20 123")
        #expect(CSVField.escape("@SUM(A1)") == "'@SUM(A1)")
        #expect(CSVField.escape("-cmd") == "'-cmd")
        #expect(CSVField.escape("\tx") == "'\tx")
        // Numbers, percentages and ordinary text are left alone.
        #expect(CSVField.escape("-12,50") == "-12,50")
        #expect(CSVField.escape("21%") == "21%")
        #expect(CSVField.escape("Praatnet") == "Praatnet")
        #expect(CSVField.escape("a;b") == "\"a;b\"")
    }

    @Test func exportsEscapeSenderText() {
        let lines = [ClaimLine(date: .now, sender: "=1+1", description: "Lunch", amount: 12.5, relativePath: "Private/2026/Receipts/a.pdf")]
        let text = String(decoding: ExpenseClaim.csv(lines).dropFirst(3), as: UTF8.self)
        #expect(text.contains(";'=1+1;"))
        #expect(!text.contains(";=1+1;"))
    }

    @Test func importPathsStayInTheArchive() {
        #expect(ArchivePaths.isDocumentPath("Private/2026/Invoices/2026-02-20 Praatnet - Factuur.pdf"))
        #expect(!ArchivePaths.isDocumentPath("../../Library/secret.pdf"))
        #expect(!ArchivePaths.isDocumentPath("Private/../../x.pdf"))
        #expect(!ArchivePaths.isDocumentPath("/etc/x.pdf"))
        #expect(!ArchivePaths.isDocumentPath("~/x.pdf"))
        #expect(!ArchivePaths.isDocumentPath("Private//x.pdf"))
        #expect(!ArchivePaths.isDocumentPath("Private/2026/notes.txt"))
        #expect(!ArchivePaths.isDocumentPath("x.pdf"))
        #expect(!ArchivePaths.isDocumentPath("Export/Paper Trail Index.pdf"))
        #expect(!ArchivePaths.isDocumentPath("Inbox/a.pdf"))
        #expect(!ArchivePaths.isDocumentPath("Private/a\nb.pdf"))
    }

    @Test func epcFieldsStayOnTheirLine() throws {
        let payload = try EPCQRCode.payload(name: "Praatnet\nNL00TEST0999888777\nEUR9999.00", iban: "NL91ABNA0417164300",
                                            bic: "AB\nCD", amount: 45.99, reference: "BD-1\r\nEUR1.00")
        let lines = payload.components(separatedBy: "\n")
        #expect(lines.count == 11)
        #expect(lines[4] == "")
        #expect(lines[5] == "Praatnet NL00TEST0999888777 EUR9999.00")
        #expect(lines[6] == "NL91ABNA0417164300")
        #expect(lines[7] == "EUR45.99")
        #expect(lines[10] == "BD-1 EUR1.00")
        #expect(EPCQRCode.validBIC("abna nl 2a") == "ABNANL2A")
    }
}
