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

    public init(date: Date, sender: String, description: String, amount: Double?, relativePath: String) {
        self.date = date
        self.sender = sender
        self.description = description
        self.amount = amount
        self.relativePath = relativePath
    }
}

/// Builds the files of an expense claim: a CSV for Excel/Numbers and a PDF with a summary
/// page followed by every receipt.
public enum ExpenseClaim {
    public static func total(_ lines: [ClaimLine]) -> Double {
        Double(lines.compactMap(\.amount).map { Int(($0 * 100).rounded()) }.reduce(0, +)) / 100
    }

    /// Semicolon-separated with a UTF-8 byte order mark, so Excel in Dutch settings opens it in
    /// columns and shows accents; amounts use the locale's decimal separator.
    public static func csv(_ lines: [ClaimLine], locale: Locale = .current, calendar: Calendar? = nil) -> Data {
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
        var rows = [[String(localized: "Date", bundle: .module), String(localized: "Sender", bundle: .module),
                     String(localized: "Description", bundle: .module), String(localized: "Amount (EUR)", bundle: .module),
                     String(localized: "Document", bundle: .module)]]
        for line in lines {
            rows.append([namer.dateString(line.date), line.sender, line.description, amount(line.amount), line.relativePath])
        }
        rows.append(["", String(localized: "Total", bundle: .module), "", amount(total(lines)), ""])
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
        let columns: [CGFloat] = [margin, margin + 78, margin + 210, PDFBuilder.pageWidth - margin]  // date, sender, description, amount (right edge)
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
            draw(String(localized: "Amount", bundle: .module), x: 0, bold: true, rightAlignedTo: columns[3])
            y -= rowHeight
        }
        header()
        for line in lines {
            if y < margin + rowHeight * 2 {
                context.endPDFPage()
                newPage()
                header()
            }
            draw(namer.dateString(line.date), x: columns[0], maxWidth: 74)
            draw(line.sender, x: columns[1], maxWidth: 126)
            draw(line.description, x: columns[2], maxWidth: 200)
            draw(amountText(line.amount), x: 0, rightAlignedTo: columns[3], maxWidth: 90)
            y -= rowHeight
        }
        y -= 6
        draw(String(localized: "Total", bundle: .module), x: columns[2], bold: true)
        draw(total(lines).formatted(.currency(code: "EUR").locale(locale)), x: 0, bold: true, rightAlignedTo: columns[3])
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
