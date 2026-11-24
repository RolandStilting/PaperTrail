import CoreGraphics
import Foundation
import Testing
@testable import PaperTrailKit

@Suite("ExpenseClaim")
struct ExpenseClaimTests {
    static let calendar = TestSupport.calendar
    static func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 3, day: d, hour: 12))! }

    static let lines = [
        ClaimLine(date: day(7), sender: "Bouwmarkt Voorbeeld", description: "Kassabon verf; tape", amount: 49.02, relativePath: "Private/2026/Receipts/a.pdf",
                  ledgerCode: "4510", ledgerDescription: "Kantoorbenodigdheden"),
        ClaimLine(date: day(9), sender: "Parkeren \"Test\"", description: "Parkeerbon", amount: 4.5, relativePath: "Private/2026/Receipts/b.pdf"),
        ClaimLine(date: day(10), sender: "Testmarkt", description: "Bon", amount: nil, relativePath: "Private/2026/Receipts/c.pdf"),
    ]

    @Test func totalSkipsMissingAmounts() {
        #expect(ExpenseClaim.total(Self.lines) == 53.52)
    }

    @Test func csvForDutchExcel() {
        let data = ExpenseClaim.csv(Self.lines, locale: Locale(identifier: "nl_NL"), calendar: Self.calendar)
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        let rows = String(decoding: data.dropFirst(3), as: UTF8.self).components(separatedBy: "\r\n")
        #expect(rows[0] == "Date;Sender;Description;Amount (EUR);Ledger code;Ledger description;Document")
        #expect(rows[1] == "2026-03-07;Bouwmarkt Voorbeeld;\"Kassabon verf; tape\";49,02;4510;Kantoorbenodigdheden;Private/2026/Receipts/a.pdf")
        #expect(rows[2] == "2026-03-09;\"Parkeren \"\"Test\"\"\";Parkeerbon;4,50;;;Private/2026/Receipts/b.pdf")
        #expect(rows[3] == "2026-03-10;Testmarkt;Bon;;;;Private/2026/Receipts/c.pdf")
        #expect(rows[4] == ";Total;;53,52;;;")
    }

    @Test func pdfHasSummaryThenReceipts() throws {
        let receipt = try PDFBuilder.makePDF(from: [Self.image(), Self.image()])
        let pdf = try ExpenseClaim.pdf(title: "Expense claim Company1", subtitle: "3 expenses", lines: Self.lines,
                                       receipts: [receipt, receipt], calendar: Self.calendar)
        let document = try #require(CGPDFDocument(CGDataProvider(data: pdf as CFData)!))
        #expect(document.numberOfPages == 1 + 4)
    }

    @Test func longClaimsGetMoreSummaryPages() throws {
        let many = Array(repeating: Self.lines[0], count: 80)
        let pdf = try ExpenseClaim.pdf(title: "T", subtitle: "S", lines: many, receipts: [], calendar: Self.calendar)
        #expect((CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages ?? 0) >= 2)
    }

    static func image() -> CGImage {
        let context = CGContext(data: nil, width: 20, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        return context.makeImage()!
    }
}
