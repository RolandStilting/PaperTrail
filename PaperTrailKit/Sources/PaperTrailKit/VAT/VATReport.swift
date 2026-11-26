import CoreGraphics
import CoreText
import Foundation

/// How often a company files its VAT return.
public enum VATPeriodKind: String, Codable, Hashable, Sendable, CaseIterable {
    case month, quarter, year
}

/// One VAT return period, e.g. Q1 2026: from `start` up to (not including) `end`.
public struct VATPeriod: Hashable, Sendable, Identifiable {
    public var kind: VATPeriodKind
    public var start: Date
    public var end: Date
    public var id: Date { start }

    public static func containing(_ date: Date, kind: VATPeriodKind, calendar: Calendar? = nil) -> VATPeriod {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let c = calendar.dateComponents([.year, .month], from: date)
        let year = c.year ?? 2000, month = c.month ?? 1
        let (startMonth, months): (Int, Int) = switch kind {
        case .month: (month, 1)
        case .quarter: ((month - 1) / 3 * 3 + 1, 3)
        case .year: (1, 12)
        }
        let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: 1))!
        let end = calendar.date(byAdding: .month, value: months, to: start)!
        return VATPeriod(kind: kind, start: start, end: end)
    }

    public func previous(calendar: Calendar? = nil) -> VATPeriod {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        return .containing(calendar.date(byAdding: .day, value: -1, to: start)!, kind: kind, calendar: calendar)
    }

    public func next(calendar: Calendar? = nil) -> VATPeriod { .containing(end, kind: kind, calendar: calendar) }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// The usual Dutch deadline for a monthly or quarterly return: the last day of the month
    /// after the period. nil for yearly returns, whose deadline differs. General information
    /// only; the tax agency's letter or the accountant decides.
    public func usualDeadline(calendar: Calendar? = nil) -> Date? {
        guard kind != .year else { return nil }
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let afterNextMonth = calendar.date(byAdding: .month, value: 1, to: end)!
        return calendar.date(byAdding: .day, value: -1, to: afterNextMonth)
    }

    /// "March 2026", "Q1 2026" or "2026".
    public func label(locale: Locale = .current, calendar: Calendar? = nil) -> String {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let c = calendar.dateComponents([.year, .month], from: start)
        let year = String(c.year ?? 0)
        switch kind {
        case .month:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return formatter.string(from: start)
        case .quarter: return "Q\(((c.month ?? 1) - 1) / 3 + 1) \(year)"
        case .year: return year
        }
    }
}

/// A document in a VAT overview.
public struct VATReportItem: Sendable, Hashable {
    public var date: Date
    public var sender: String
    public var description: String
    /// Total paid, if known.
    public var amount: Double?
    public var vat: VATInfo
    /// Filed under another owner and reimbursed by this company (expense claim).
    public var isReimbursedExpense: Bool
    public var relativePath: String
    /// The document's ledger code and description; empty when none.
    public var ledgerCode: String
    public var ledgerDescription: String

    public init(date: Date, sender: String, description: String, amount: Double?, vat: VATInfo, isReimbursedExpense: Bool, relativePath: String,
                ledgerCode: String = "", ledgerDescription: String = "") {
        self.date = date
        self.sender = sender
        self.description = description
        self.amount = amount
        self.vat = vat
        self.isReimbursedExpense = isReimbursedExpense
        self.relativePath = relativePath
        self.ledgerCode = ledgerCode
        self.ledgerDescription = ledgerDescription
    }

    public enum Kind: Sendable { case domestic, foreign, reverseCharge, vatMissing }

    public var kind: Kind {
        if vat.isReverseCharge { return .reverseCharge }
        if vat.isForeign { return .foreign }
        return vat.lines.isEmpty ? .vatMissing : .domestic
    }
}

/// Input VAT to reclaim for one company and period. It counts; it doesn't decide what is
/// deductible — that stays with the user and their accountant.
public struct VATReport: Sendable {
    public var company: String
    public var period: VATPeriod
    public var items: [VATReportItem]
    /// The company's input VAT ledger codes; in the CSV for reclaimable (domestic) VAT lines.
    public var vatLedgerCodes: [VATLedgerCode]

    public init(company: String, period: VATPeriod, items: [VATReportItem], vatLedgerCodes: [VATLedgerCode] = []) {
        self.company = company
        self.period = period
        self.items = items.sorted { $0.date < $1.date }
        self.vatLedgerCodes = vatLedgerCodes
    }

    /// The VAT ledger code for a line of `item`: only for VAT that is reclaimed.
    func vatLedgerCode(for line: VATLine, in item: VATReportItem) -> String {
        guard item.kind == .domestic else { return "" }
        return vatLedgerCodes.first { abs($0.rate - line.rate) < 0.001 }?.code ?? ""
    }

    public struct RateTotal: Sendable, Hashable {
        public var rate: Double
        public var base: Double
        public var vat: Double
    }

    public var domestic: [VATReportItem] { items.filter { $0.kind == .domestic } }
    public var foreign: [VATReportItem] { items.filter { $0.kind == .foreign } }
    /// Reverse charge and documents without VAT found: to check, not in the total.
    public var toCheck: [VATReportItem] { items.filter { $0.kind == .reverseCharge || $0.kind == .vatMissing } }

    /// Totals per Dutch rate for the domestic documents, highest rate first.
    public var totalsPerRate: [RateTotal] {
        var cents: [Double: (base: Int, vat: Int)] = [:]
        for item in domestic {
            for line in item.vat.lines {
                let current = cents[line.rate] ?? (0, 0)
                let base = Self.amounts(of: line, in: item).excl ?? 0
                cents[line.rate] = (current.base + Int((base * 100).rounded()), current.vat + Int((line.amount * 100).rounded()))
            }
        }
        return cents.map { RateTotal(rate: $0.key, base: Double($0.value.base) / 100, vat: Double($0.value.vat) / 100) }
            .sorted { $0.rate > $1.rate }
    }

    /// Amount excluding and including VAT for one VAT line. When the document doesn't state the
    /// base, it is calculated: for a single VAT line, total minus VAT; incl. is always excl. + VAT.
    public static func amounts(of line: VATLine, in item: VATReportItem) -> (excl: Double?, incl: Double?) {
        let excl = line.base ?? (item.vat.lines.count == 1 ? item.amount.map { (($0 - line.amount) * 100).rounded() / 100 } : nil)
        return (excl, excl.map { (($0 + line.amount) * 100).rounded() / 100 })
    }

    public var totalToReclaim: Double {
        Double(totalsPerRate.map { Int(($0.vat * 100).rounded()) }.reduce(0, +)) / 100
    }

    public var foreignVAT: Double {
        Double(foreign.map { Int(($0.vat.total * 100).rounded()) }.reduce(0, +)) / 100
    }

    // MARK: Export

    /// Semicolon CSV for Excel/Numbers: every document with its VAT lines and a status.
    public func csv(locale: Locale = .current, calendar: Calendar? = nil) -> Data {
        let namer = FileNamer(calendar: calendar ?? FileNamer.defaultCalendar())
        let decimal = locale.decimalSeparator ?? ","
        func number(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0).replacingOccurrences(of: ".", with: decimal) } ?? ""
        }
        func rateText(_ rate: Double) -> String {
            (rate == rate.rounded() ? String(Int(rate)) : String(rate).replacingOccurrences(of: ".", with: decimal)) + "%"
        }
        func status(_ item: VATReportItem) -> String {
            switch item.kind {
            case .domestic: item.isReimbursedExpense ? String(localized: "Reclaim (reimbursed expense)", bundle: .module) : String(localized: "Reclaim", bundle: .module)
            case .foreign: String(localized: "Foreign VAT", bundle: .module)
            case .reverseCharge: String(localized: "Reverse charge – check", bundle: .module)
            case .vatMissing: String(localized: "No VAT found – check", bundle: .module)
            }
        }
        var rows = [[String(localized: "Date", bundle: .module), String(localized: "Sender", bundle: .module), String(localized: "Description", bundle: .module),
                     String(localized: "Rate", bundle: .module), String(localized: "Excl. VAT", bundle: .module), String(localized: "VAT", bundle: .module),
                     String(localized: "Incl. VAT", bundle: .module), String(localized: "Status", bundle: .module),
                     String(localized: "Ledger code", bundle: .module), String(localized: "Ledger description", bundle: .module),
                     String(localized: "VAT ledger code", bundle: .module), String(localized: "Document", bundle: .module)]]
        for item in items {
            if item.vat.lines.isEmpty {
                rows.append([namer.dateString(item.date), item.sender, item.description, "", "", "", number(item.amount), status(item),
                             item.ledgerCode, item.ledgerDescription, "", item.relativePath])
                continue
            }
            for line in item.vat.lines {
                let amounts = Self.amounts(of: line, in: item)
                rows.append([namer.dateString(item.date), item.sender, item.description, rateText(line.rate),
                             number(amounts.excl), number(line.amount), number(amounts.incl), status(item),
                             item.ledgerCode, item.ledgerDescription, vatLedgerCode(for: line, in: item), item.relativePath])
            }
        }
        rows.append([])
        for total in totalsPerRate {
            rows.append(["", String(localized: "Total", bundle: .module) + " " + rateText(total.rate), "", rateText(total.rate),
                         number(total.base), number(total.vat), number(((total.base + total.vat) * 100).rounded() / 100), "", "", "",
                         vatLedgerCodes.first { abs($0.rate - total.rate) < 0.001 }?.code ?? "", ""])
        }
        rows.append(["", String(localized: "VAT to reclaim", bundle: .module), "", "", "", number(totalToReclaim), "", "", "", "", "", ""])
        if !foreign.isEmpty {
            rows.append(["", String(localized: "Foreign VAT (not in the total)", bundle: .module), "", "", "", number(foreignVAT), "", "", "", "", "", ""])
        }
        let text = rows.map { $0.map(CSVField.escape).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    /// The documents in the order the PDF lists them: reclaim, foreign, to check.
    public var documentsInOrder: [VATReportItem] { domestic + foreign + toCheck }

    /// A printable summary: totals per rate, then the documents per group, then (if given) every
    /// document itself, in `documentsInOrder` order.
    public func pdf(documents: [Data] = [], locale: Locale = .current, calendar: Calendar? = nil) throws(PDFBuilderError) -> Data {
        let namer = FileNamer(calendar: calendar ?? FileNamer.defaultCalendar())
        func money(_ value: Double) -> String { value.formatted(.currency(code: "EUR").locale(locale)) }
        func rateText(_ rate: Double) -> String { rate == rate.rounded() ? "\(Int(rate)) %" : "\(rate) %" }

        var writer = try SimplePDFWriter()
        writer.text(String(localized: "VAT overview \(company)", bundle: .module), size: 18, bold: true)
        writer.text(period.label(locale: locale, calendar: calendar) + " · " + String(localized: "input VAT to reclaim", bundle: .module), size: 11)
        writer.space(14)
        for total in totalsPerRate {
            writer.row([String(localized: "Rate \(rateText(total.rate))", bundle: .module),
                        String(localized: "excl. \(money(total.base))", bundle: .module), money(total.vat)], bold: false)
        }
        writer.row([String(localized: "VAT to reclaim", bundle: .module), "", money(totalToReclaim)], bold: true)
        if !foreign.isEmpty {
            writer.row([String(localized: "Foreign VAT (not in the total)", bundle: .module), "", money(foreignVAT)], bold: false)
        }

        func group(_ title: String, _ list: [VATReportItem]) {
            guard !list.isEmpty else { return }
            writer.space(14)
            writer.text(title, size: 12, bold: true)
            for item in list {
                let rates = item.vat.lines.map { rateText($0.rate) }.joined(separator: " + ")
                let marker = item.isReimbursedExpense ? " *" : ""
                writer.row([namer.dateString(item.date), item.sender + marker, rates, money(item.vat.total)], bold: false)
            }
        }
        group(String(localized: "Documents", bundle: .module), domestic)
        group(String(localized: "Foreign VAT", bundle: .module), foreign)
        group(String(localized: "To check (not in the total)", bundle: .module), toCheck)
        if items.contains(where: \.isReimbursedExpense) {
            writer.space(8)
            writer.text(String(localized: "* Personal expense reimbursed by \(company).", bundle: .module), size: 9)
        }
        writer.space(8)
        writer.text(String(localized: "Made by Paper Trail from the documents' VAT lines. Check deductibility with your accountant.", bundle: .module), size: 9)
        if !documents.isEmpty {
            writer.text(String(localized: "The documents follow on the next pages, in the order listed.", bundle: .module), size: 9)
        }
        return writer.finish(appending: documents)
    }
}

/// Minimal A4 text writer: lines and right-aligned columns, new pages as needed.
struct SimplePDFWriter {
    private let output = NSMutableData()
    private let context: CGContext
    private var page = CGRect(x: 0, y: 0, width: PDFBuilder.pageWidth, height: PDFPaginator.a4Height)
    private let margin: CGFloat = 48
    private var y: CGFloat = 0

    init() throws(PDFBuilderError) {
        var box = page
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw .couldNotCreateContext }
        self.context = context
        context.beginPDFPage(nil)
        y = page.height - margin
    }

    private mutating func ensureSpace(_ height: CGFloat) {
        if y - height < margin {
            context.endPDFPage()
            context.beginPDFPage(nil)
            y = page.height - margin
        }
    }

    private func draw(_ string: String, x: CGFloat, size: CGFloat, bold: Bool, rightEdge: CGFloat? = nil, maxWidth: CGFloat) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        if let truncated = CTLineCreateTruncatedLine(line, maxWidth, .end, CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))) {
            line = truncated
        }
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: rightEdge.map { $0 - width } ?? x, y: y)
        CTLineDraw(line, context)
    }

    mutating func text(_ string: String, size: CGFloat = 10, bold: Bool = false) {
        ensureSpace(size + 8)
        draw(string, x: margin, size: size, bold: bold, maxWidth: page.width - 2 * margin)
        y -= size + 8
    }

    mutating func space(_ height: CGFloat) { y -= height }

    /// Up to four columns; the last one is right-aligned (amounts).
    mutating func row(_ columns: [String], bold: Bool) {
        ensureSpace(18)
        let starts: [CGFloat] = [margin, margin + 80, margin + 300]
        let right = page.width - margin
        for (index, value) in columns.enumerated() {
            if index == columns.count - 1 {
                draw(value, x: 0, size: 10, bold: bold, rightEdge: right, maxWidth: 110)
            } else {
                let width = (index + 1 < starts.count ? starts[index + 1] : right - 110) - starts[min(index, starts.count - 1)] - 6
                draw(value, x: starts[min(index, starts.count - 1)], size: 10, bold: bold, maxWidth: max(40, width))
            }
        }
        y -= 18
    }

    /// Ends the text pages, then adds every page of each document unchanged.
    mutating func finish(appending documents: [Data] = []) -> Data {
        context.endPDFPage()
        for data in documents {
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0 else { continue }
            for number in 1...document.numberOfPages {
                guard let page = document.page(at: number) else { continue }
                var box = page.getBoxRect(.mediaBox)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                context.drawPDFPage(page)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return output as Data
    }
}
