import CoreGraphics
import Foundation
import Testing
@testable import PaperTrailKit

@Suite("VATReport")
struct VATReportTests {
    static let calendar = TestSupport.calendar
    static func day(_ month: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: d, hour: 12))! }

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
                      vat: VATInfo(lines: [VATLine(rate: 9, base: 4.49, amount: 0.40), VATLine(rate: 21, base: 10.33, amount: 2.17)]), isReimbursedExpense: true, relativePath: "b.pdf"),
        VATReportItem(date: day(2, 2), sender: "Gasthof Beispiel", description: "Rechnung", amount: 204,
                      vat: VATInfo(lines: [VATLine(rate: 7, base: 168.22, amount: 11.78)], isForeign: true), isReimbursedExpense: false, relativePath: "c.pdf"),
        VATReportItem(date: day(2, 4), sender: "Example Software", description: "Licence", amount: 600,
                      vat: VATInfo(lines: [VATLine(rate: 0, base: 600, amount: 0)], isReverseCharge: true), isReimbursedExpense: false, relativePath: "d.pdf"),
        VATReportItem(date: day(1, 15), sender: "Proefzorg", description: "Polis", amount: 148.5,
                      vat: VATInfo(), isReimbursedExpense: false, relativePath: "e.pdf"),
    ])

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
        #expect(rows.contains("2026-03-21;Drogisterij Voorbeeld;Kassabon;9%;4,49;0,40;17,39;Reclaim (reimbursed expense);b.pdf"))
        #expect(rows.contains("2026-03-21;Drogisterij Voorbeeld;Kassabon;21%;10,33;2,17;;Reclaim (reimbursed expense);b.pdf"))
        #expect(rows.contains(";VAT to reclaim;;;;150,73;;;"))
        #expect(rows.contains(";Foreign VAT (not in the total);;;;11,78;;;"))
    }

    @Test func pdfRenders() throws {
        let pdf = try Self.report.pdf(calendar: Self.calendar)
        #expect(CGPDFDocument(CGDataProvider(data: pdf as CFData)!)?.numberOfPages == 1)
    }
}
