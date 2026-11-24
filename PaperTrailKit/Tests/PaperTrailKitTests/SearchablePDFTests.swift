import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PaperTrailKit

/// Synthetic pages only: a white page with a grey bar where the "text" is.
@Suite("SearchablePDF")
struct SearchablePDFTests {
    func page(width: Int = 1240, height: Int = 1754) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        context.fill(CGRect(x: 124, y: 1403, width: 744, height: 88))
        return context.makeImage()!
    }

    let line = RecognizedLine(text: "Voorbeeld Energie jaarnota 2026", box: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05))

    @Test func textBecomesSearchableWhereItWasFound() throws {
        let scan = try PDFBuilder.makePDF(from: [page(), page()])
        #expect((PDFDocument(data: scan)?.string ?? "").isEmpty)

        let searchable = try #require(SearchablePDF.addingTextLayer(to: scan, pages: [[line]]))
        let document = try #require(PDFDocument(data: searchable))
        #expect(document.pageCount == 2)
        // The scan's images are copied, not re-encoded: the file barely grows.
        #expect(searchable.count < scan.count + 40_000, "scan \(scan.count) bytes, searchable \(searchable.count) bytes")
        #expect(document.string?.contains("Voorbeeld Energie jaarnota 2026") == true)

        // Selecting the text highlights the place on the scan.
        let pdfPage = try #require(document.page(at: 0))
        let size = pdfPage.bounds(for: .mediaBox).size
        let found = try #require(document.findString("jaarnota", withOptions: []).first)
        let bounds = found.bounds(for: pdfPage)
        #expect(abs(bounds.midY - 0.825 * size.height) < 0.03 * size.height)
        #expect(bounds.minX > 0.1 * size.width && bounds.maxX < 0.7 * size.width)
    }

    @Test func pagesLookTheSame() throws {
        let scan = try PDFBuilder.makePDF(from: [page()])
        let searchable = try #require(SearchablePDF.addingTextLayer(to: scan, pages: [[line]]))
        let before = try #require(PDFPageRenderer.renderPages(of: scan, scale: 0.5).first)
        let after = try #require(PDFPageRenderer.renderPages(of: searchable, scale: 0.5).first)
        #expect(before.width == after.width && before.height == after.height)
        let a = pixels(before), b = pixels(after)
        let different = zip(a, b).filter { abs(Int($0) - Int($1)) > 8 }.count
        #expect(Double(different) / Double(a.count) < 0.001)
    }

    @Test func nothingToAdd() throws {
        let scan = try PDFBuilder.makePDF(from: [page()])
        #expect(SearchablePDF.addingTextLayer(to: scan, pages: [[]]) == nil)
        #expect(SearchablePDF.addingTextLayer(to: Data("not a pdf".utf8), pages: [[line]]) == nil)
    }

    func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}
