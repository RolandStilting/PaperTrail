import CoreGraphics
import CoreText
import Foundation

/// A line of text found by OCR on a page image.
public struct RecognizedLine: Sendable, Hashable {
    public var text: String
    /// Where it sits on the page, normalized to 0...1 with the origin at the lower left
    /// (Vision's default, and the same direction as PDF coordinates).
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Makes scanned PDFs searchable: each page is copied as it is, with the recognised text
/// drawn invisibly on top at the place it was found. Finder, Spotlight, Files and Preview
/// can then search and select the text; the page looks exactly the same.
public enum SearchablePDF {
    /// - Parameters:
    ///   - pdf: The scanned PDF.
    ///   - pages: Recognised lines per page, in page order. Pages without an entry get no text.
    /// - Returns: The new PDF, or nil when it can't be done safely (no pages, rotated pages,
    ///   no text at all); then keep the original.
    public static func addingTextLayer(to pdf: Data, pages: [[RecognizedLine]]) -> Data? {
        guard pages.contains(where: { !$0.isEmpty }),
              let provider = CGDataProvider(data: pdf as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else { return nil }
        // The OCR images are rendered without rotation; a rotated page would get its text in
        // the wrong place, so such documents are left as they are.
        for number in 1...document.numberOfPages where document.page(at: number)?.rotationAngle ?? 0 != 0 {
            return nil
        }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }

        for number in 1...document.numberOfPages {
            guard let page = document.page(at: number) else { return nil }
            let crop = page.getBoxRect(.cropBox)
            var box = CGRect(origin: .zero, size: crop.size)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)

            context.saveGState()
            context.clip(to: box)
            context.translateBy(x: -crop.minX, y: -crop.minY)
            context.drawPDFPage(page)
            context.restoreGState()

            if number <= pages.count {
                for line in pages[number - 1] { drawInvisible(line, pageSize: box.size, in: context) }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    /// Draws the line's text invisibly, stretched to fill its box, so selecting it in a PDF
    /// viewer highlights the right place on the scan.
    static func drawInvisible(_ line: RecognizedLine, pageSize: CGSize, in context: CGContext) {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rect = CGRect(x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                          width: line.box.width * pageSize.width, height: line.box.height * pageSize.height)
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }

        let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, &descent, nil))
        guard width > 0 else { return }

        context.saveGState()
        context.textMatrix = .identity
        context.setTextDrawingMode(.invisible)
        context.translateBy(x: rect.minX, y: rect.minY + descent)
        context.scaleBy(x: rect.width / width, y: 1)
        context.textPosition = .zero
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}
