import CoreGraphics
import CoreText
import Foundation

/// One line of an expense claim.
public struct ClaimLine: Sendable, Hashable {
    public var date: Date
    public var sender: String
    public var description: String
    /// nil when the receipt has no known amount; shown as missing and left out of the total.
    public var amount: Double?
    /// Where the receipt is in the archive, relative to "Paper Trail".
    public var relativePath: String
    /// The receipt's ledger code and description (from its own owner's list); empty when none.
    public var ledgerCode: String
    public var ledgerDescription: String
    /// VAT the reimbursing company reclaims on this receipt (Dutch VAT only), with its codes.
    public var vat: [ClaimVATLine]

    public init(date: Date, sender: String, description: String, amount: Double?, relativePath: String,
                ledgerCode: String = "", ledgerDescription: String = "", vat: [ClaimVATLine] = []) {
        self.date = date
        self.sender = sender
        self.description = description
        self.amount = amount
        self.relativePath = relativePath
        self.ledgerCode = ledgerCode
        self.ledgerDescription = ledgerDescription
        self.vat = vat
    }

    /// Reclaimable VAT in total.
    public var vatTotal: Double { ExpenseClaim.sum(vat.map(\.amount)) }

    /// The amount without the reclaimable VAT: what is booked on the ledger code.
    public var amountExcludingVAT: Double? {
        amount.map { (($0 - vatTotal) * 100).rounded() / 100 }
    }

    public func vat(rate: Double) -> [ClaimVATLine] { vat.filter { abs($0.rate - rate) < 0.001 } }
}

/// One VAT rate on a claimed receipt, with the reimbursing company's input VAT ledger code.
public struct ClaimVATLine: Sendable, Hashable {
    public var rate: Double
    public var amount: Double
    public var ledgerCode: String

    public init(rate: Double, amount: Double, ledgerCode: String = "") {
        self.rate = rate
        self.amount = amount
        self.ledgerCode = ledgerCode
    }

    /// The reclaimable lines of a receipt: none for foreign VAT or reverse charge, which the
    /// Dutch return doesn't reclaim this way.
    public static func reclaimable(_ info: VATInfo?, codes: [VATLedgerCode]) -> [ClaimVATLine] {
        guard let info, !info.isForeign, !info.isReverseCharge else { return [] }
        return info.lines.filter { $0.amount != 0 }.map { line in
            ClaimVATLine(rate: line.rate, amount: line.amount,
                         ledgerCode: codes.first { abs($0.rate - line.rate) < 0.001 }?.code ?? "")
        }
    }
}

/// Builds the files of an expense claim: a CSV for Excel/Numbers and a PDF with a summary
/// page followed by every receipt.
public enum ExpenseClaim {
    public static func total(_ lines: [ClaimLine]) -> Double {
        sum(lines.compactMap(\.amount))
    }

    static func sum(_ values: [Double]) -> Double {
        Double(values.map { Int(($0 * 100).rounded()) }.reduce(0, +)) / 100
    }

    /// Reclaimable VAT per rate over all lines, highest rate first, with the ledger code.
    public static func vatPerRate(_ lines: [ClaimLine]) -> [ClaimVATLine] {
        let all = lines.flatMap(\.vat)
        return Set(all.map(\.rate)).sorted(by: >).map { rate in
            let atRate = all.filter { $0.rate == rate }
            return ClaimVATLine(rate: rate, amount: sum(atRate.map(\.amount)), ledgerCode: atRate.first { !$0.ledgerCode.isEmpty }?.ledgerCode ?? "")
        }
    }

    /// Semicolon-separated with a UTF-8 byte order mark, so Excel in Dutch settings opens it in
    /// columns and shows accents; amounts use the locale's decimal separator.
    /// - Parameter vatCodes: The company's input VAT ledger codes; shown once, in the heading of
    ///   each VAT column ("VAT 21% (1510)"), since they are the same on every row.
    public static func csv(_ lines: [ClaimLine], vatCodes: [VATLedgerCode] = [], locale: Locale = .current, calendar: Calendar? = nil) -> Data {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let namer = FileNamer(calendar: calendar)
        let decimal = locale.decimalSeparator ?? ","
        func amount(_ value: Double?) -> String {
            guard let value else { return "" }
            return String(format: "%.2f", value).replacingOccurrences(of: ".", with: decimal)
        }
        func field(_ text: String) -> String {
            let needsQuotes = text.contains(";") || text.contains("\"") || text.contains("\n")
            return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        func vatAmount(_ line: ClaimLine, rate: Double) -> String {
            let atRate = line.vat(rate: rate)
            return atRate.isEmpty ? "" : amount(sum(atRate.map(\.amount)))
        }
        func vatHeading(_ rate: Double) -> String {
            let heading = rate == 21 ? String(localized: "VAT 21%", bundle: .module) : String(localized: "VAT 9%", bundle: .module)
            let code = vatCodes.first { abs($0.rate - rate) < 0.001 && !$0.code.isEmpty }?.code
                ?? lines.flatMap { $0.vat(rate: rate) }.first { !$0.ledgerCode.isEmpty }?.ledgerCode
            return code.map { "\(heading) (\($0))" } ?? heading
        }
        var rows = [[String(localized: "Date", bundle: .module), String(localized: "Sender", bundle: .module),
                     String(localized: "Description", bundle: .module), String(localized: "Amount (EUR)", bundle: .module),
                     String(localized: "Excl. VAT", bundle: .module), vatHeading(21), vatHeading(9),
                     String(localized: "Ledger code", bundle: .module), String(localized: "Ledger description", bundle: .module),
                     String(localized: "Document", bundle: .module)]]
        for line in lines {
            rows.append([namer.dateString(line.date), line.sender, line.description, amount(line.amount),
                         amount(line.amountExcludingVAT), vatAmount(line, rate: 21), vatAmount(line, rate: 9),
                         line.ledgerCode, line.ledgerDescription, line.relativePath])
        }
        let totals = vatPerRate(lines)
        func vatTotal(_ rate: Double) -> String { totals.first { $0.rate == rate }.map { amount($0.amount) } ?? "" }
        rows.append(["", String(localized: "Total", bundle: .module), "", amount(total(lines)),
                     amount(sum(lines.compactMap(\.amountExcludingVAT))), vatTotal(21), vatTotal(9), "", "", ""])
        let text = rows.map { $0.map(field).joined(separator: ";") }.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    /// Summary page(s) and then all pages of every receipt, in order.
    public static func pdf(title: String, subtitle: String, lines: [ClaimLine], receipts: [Data],
                           locale: Locale = .current, calendar: Calendar? = nil) throws(PDFBuilderError) -> Data {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let namer = FileNamer(calendar: calendar)
        let output = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: PDFBuilder.pageWidth, height: PDFPaginator.a4Height)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { throw .couldNotCreateContext }

        let margin: CGFloat = 48
        let rowHeight: CGFloat = 18
        // date, sender, description, ledger code, VAT (right edge), amount (right edge)
        let columns: [CGFloat] = [margin, margin + 68, margin + 172, margin + 304, PDFBuilder.pageWidth - margin - 84, PDFBuilder.pageWidth - margin]
        var y = page.height - margin
        func newPage() {
            context.beginPDFPage(nil)
            y = page.height - margin
        }
        func draw(_ text: String, x: CGFloat, size: CGFloat = 10, bold: Bool = false, rightAlignedTo right: CGFloat? = nil, maxWidth: CGFloat = 200) {
            let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes = [kCTFontAttributeName as NSAttributedString.Key: font]
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            if let truncation = CTLineCreateTruncatedLine(line, maxWidth, .end,
                                                          CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))) {
                line = truncation
            }
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: right.map { $0 - width } ?? x, y: y)
            CTLineDraw(line, context)
        }
        func amountText(_ value: Double?) -> String {
            value.map { $0.formatted(.currency(code: "EUR").locale(locale)) } ?? String(localized: "amount missing", bundle: .module)
        }

        newPage()
        draw(title, x: margin, size: 18, bold: true, maxWidth: page.width - 2 * margin)
        y -= 24
        draw(subtitle, x: margin, size: 11, maxWidth: page.width - 2 * margin)
        y -= 32
        func header() {
            draw(String(localized: "Date", bundle: .module), x: columns[0], bold: true)
            draw(String(localized: "Sender", bundle: .module), x: columns[1], bold: true)
            draw(String(localized: "Description", bundle: .module), x: columns[2], bold: true)
            draw(String(localized: "Ledger", bundle: .module), x: columns[3], bold: true)
            draw(String(localized: "VAT", bundle: .module), x: 0, bold: true, rightAlignedTo: columns[4])
            draw(String(localized: "Amount", bundle: .module), x: 0, bold: true, rightAlignedTo: columns[5])
            y -= rowHeight
        }
        header()
        for line in lines {
            if y < margin + rowHeight * 2 {
                context.endPDFPage()
                newPage()
                header()
            }
            draw(namer.dateString(line.date), x: columns[0], maxWidth: 64)
            draw(line.sender, x: columns[1], maxWidth: 98)
            draw(line.description, x: columns[2], maxWidth: 126)
            draw(line.ledgerCode, x: columns[3], maxWidth: 56)
            if !line.vat.isEmpty {
                draw(line.vatTotal.formatted(.currency(code: "EUR").locale(locale)), x: 0, rightAlignedTo: columns[4], maxWidth: 70)
            }
            draw(amountText(line.amount), x: 0, rightAlignedTo: columns[5], maxWidth: 80)
            y -= rowHeight
        }
        y -= 6
        draw(String(localized: "Total", bundle: .module), x: columns[2], bold: true)
        let vatTotals = vatPerRate(lines)
        if !vatTotals.isEmpty {
            draw(sum(vatTotals.map(\.amount)).formatted(.currency(code: "EUR").locale(locale)), x: 0, bold: true, rightAlignedTo: columns[4])
        }
        draw(total(lines).formatted(.currency(code: "EUR").locale(locale)), x: 0, bold: true, rightAlignedTo: columns[5])
        for rate in vatTotals {
            y -= rowHeight
            let percent = rate.rate == rate.rate.rounded() ? "\(Int(rate.rate)) %" : "\(rate.rate) %"
            let money = rate.amount.formatted(.currency(code: "EUR").locale(locale))
            let text = rate.ledgerCode.isEmpty
                ? String(localized: "VAT \(percent): \(money)", bundle: .module)
                : String(localized: "VAT \(percent): \(money), ledger code \(rate.ledgerCode)", bundle: .module)
            draw(text, x: columns[2], size: 9, maxWidth: page.width - columns[2] - margin)
        }
        if lines.contains(where: { $0.amount == nil }) {
            y -= rowHeight
            draw(String(localized: "Receipts without a known amount are not in the total.", bundle: .module), x: margin, size: 9, maxWidth: page.width - 2 * margin)
        }
        context.endPDFPage()

        for receipt in receipts {
            guard let provider = CGDataProvider(data: receipt as CFData), let document = CGPDFDocument(provider) else { continue }
            for number in 1...max(1, document.numberOfPages) {
                guard let receiptPage = document.page(at: number) else { continue }
                var box = receiptPage.getBoxRect(.mediaBox)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                context.drawPDFPage(receiptPage)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return output as Data
    }
}
