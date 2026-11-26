import CoreGraphics
import Foundation
import Testing
@testable import PaperTrailKit

@Suite("VATReport")
struct VATReportTests {
    static let calendar = TestSupport.calendar
    static func day(_ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 12))! }

    @Test func usualDeadline() {
        let c = Self.calendar
        let q1 = VATPeriod.containing(Self.day(2, 14), kind: .quarter, calendar: c)
        #expect(q1.usualDeadline(calendar: c).map { c.dateComponents([.month, .day], from: $0) } == DateComponents(month: 4, day: 30))
        let nov = VATPeriod.containing(Self.day(11, 3), kind: .month, calendar: c)
        #expect(nov.usualDeadline(calendar: c).map { c.dateComponents([.year, .month, .day], from: $0) } == DateComponents(year: 2026, month: 12, day: 31))
        #expect(VATPeriod.containing(Self.day(5, 1), kind: .year, calendar: c).usualDeadline(calendar: c) == nil)
    }

    @Test func periods() {
        let q = VATPeriod.containing(Self.day(2, 14), kind: .quarter, calendar: Self.calendar)
        #expect(q.label(calendar: Self.calendar) == "Q1 2026")
        #expect(q.contains(Self.day(3, 31)) && !q.contains(Self.day(4, 1)))
        #expect(q.next(calendar: Self.calendar).label(calendar: Self.calendar) == "Q2 2026")
        #expect(q.previous(calendar: Self.calendar).label(calendar: Self.calendar) == "Q4 2025")
        #expect(VATPeriod.containing(Self.day(7, 1), kind: .year, calendar: Self.calendar).label(calendar: Self.calendar) == "2026")
        #expect(VATPeriod.containing(Self.day(3, 9), kind: .month, calendar: Self.calendar).label(locale: Locale(identifier: "nl_NL"), calendar: Self.calendar) == "maart 2026")
    }

    static let report = VATReport(company: "Company1", period: .containing(day(3, 1), kind: .quarter, calendar: calendar), items: [
        VATReportItem(date: day(3, 9), sender: "Schildersbedrijf Testkwast", description: "Factuur", amount: 853.66,
                      vat: VATInfo(lines: [VATLine(rate: 21, base: 705.50, amount: 148.16)]), isReimbursedExpense: false, relativePath: "a.pdf"),
        VATReportItem(date: day(3, 21), sender: "Drogisterij Voorbeeld", description: "Kassabon", amount: 17.39,
                      vat: VATInfo(lines: [VATLine(rate: 9, base: 4.49, amount: 0.40), VATLine(rate: 21, base: 10.33, amount: 2.17)]), isReimbursedExpense: true, relativePath: "b.pdf",
                      ledgerCode: "4510", ledgerDescription: "Kantoorbenodigdheden"),
        VATReportItem(date: day(2, 2), sender: "Gasthof Beispiel", description: "Rechnung", amount: 204,
                      vat: VATInfo(lines: [VATLine(rate: 7, base: 168.22, amount: 11.78)], isForeign: true), isReimbursedExpense: false, relativePath: "c.pdf"),
        VATReportItem(date: day(2, 4), sender: "Example Software", description: "Licence", amount: 600,
                      vat: VATInfo(lines: [VATLine(rate: 0, base: 600, amount: 0)], isReverseCharge: true), isReimbursedExpense: false, relativePath: "d.pdf"),
        VATReportItem(date: day(1, 15), sender: "Proefzorg", description: "Polis", amount: 148.5,
                      vat: VATInfo(), isReimbursedExpense: false, relativePath: "e.pdf"),
    ], vatLedgerCodes: [VATLedgerCode(rate: 21, code: "1510"), VATLedgerCode(rate: 9, code: "1511")])

    @Test func totalsPerRateAndGroups() {
        let report = Self.report
        #expect(report.totalsPerRate == [VATReport.RateTotal(rate: 21, base: 715.83, vat: 150.33), VATReport.RateTotal(rate: 9, base: 4.49, vat: 0.40)])
        #expect(report.totalToReclaim == 150.73)
        #expect(report.foreignVAT == 11.78)
        #expect(report.toCheck.map(\.sender) == ["Proefzorg", "Example Software"])
    }

    @Test func csvHasALinePerRateAndTotals() {
        let text = String(decoding: Self.report.csv(locale: Locale(identifier: "nl_NL"), calendar: Self.calendar).dropFirst(3), as: UTF8.self)
        let rows = text.components(separatedBy: "\r\n")
        #expect(rows[0] == "Date;Sender;Description;Rate;Excl. VAT;VAT;Incl. VAT;Status;Ledger code;Ledger description;VAT ledger code;Document")
        #expect(rows.contains("2026-03-21;Drogisterij Voorbeeld;Kassabon;9%;4,49;0,40;4,89;Reclaim (reimbursed expense);4510;Kantoorbenodigdheden;1511;b.pdf"))
        #expect(rows.contains("2026-03-21;Drogisterij Voorbeeld;Kassabon;21%;10,33;2,17;12,50;Reclaim (reimbursed expense);4510;Kantoorbenodigdheden;1510;b.pdf"))
        #expect(rows.contains("2026-01-15;Proefzorg;Polis;;;;148,50;No VAT found – check;;;;e.pdf"))
        #expect(rows.contains(";VAT to reclaim;;;;150,73;;;;;;"))
        #expect(rows.contains(";Foreign VAT (not in the total);;;;11,78;;;;;;"))
        #expect(rows.contains { $0.hasPrefix("2026-02-02;Gasthof Beispiel;Rechnung;7%;") && $0.hasSuffix(";Foreign VAT;;;;c.pdf") })
        #expect(rows.contains { $0.hasPrefix(";Total 21%;;21%;") && $0.hasSuffix(";1510;") })
    }

    @Test func pdfRenders() throws {
        let pdf = try Self.report.pdf(calendar: Self.calendar)
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 1)
    }

    @Test func pdfAppendsEveryDocumentInListOrder() throws {
        let page = try PDFBuilder.makePDF(from: [ExpenseClaimTests.image()])
        let twoPages = try PDFBuilder.makePDF(from: [ExpenseClaimTests.image(), ExpenseClaimTests.image()])
        #expect(Self.report.documentsInOrder.map(\.sender) == ["Schildersbedrijf Testkwast", "Drogisterij Voorbeeld", "Gasthof Beispiel", "Proefzorg", "Example Software"])
        let pdf = try Self.report.pdf(documents: [page, twoPages, page, page, page], calendar: Self.calendar)
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 1 + 6)
    }

    @Test func missingBaseIsCalculatedFromTheTotal() {
        let item = VATReportItem(date: Self.day(3, 1), sender: "Parkeergarage Proef", description: "Parkeren", amount: 12.10,
                                 vat: VATInfo(lines: [VATLine(rate: 21, amount: 2.10)]), isReimbursedExpense: false, relativePath: "p.pdf")
        let amounts = VATReport.amounts(of: item.vat.lines[0], in: item)
        #expect(amounts.excl == 10.00 && amounts.incl == 12.10)
        let report = VATReport(company: "Company1", period: .containing(Self.day(3, 1), kind: .quarter, calendar: Self.calendar), items: [item])
        #expect(report.totalsPerRate == [VATReport.RateTotal(rate: 21, base: 10, vat: 2.10)])
    }
}
