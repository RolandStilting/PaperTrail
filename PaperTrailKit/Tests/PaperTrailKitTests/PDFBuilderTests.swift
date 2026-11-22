import CoreGraphics
import Foundation
import Testing
@testable import PaperTrailKit

@Suite("PDFBuilder")
struct PDFBuilderTests {
    /// A synthetic grey test image; no real document content.
    static func testImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func buildsOnePagePerImageAtA4Width() throws {
        let data = try PDFBuilder.makePDF(from: [Self.testImage(width: 1000, height: 1414), Self.testImage(width: 800, height: 400)])
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 2)
        let first = try #require(document.page(at: 1)).getBoxRect(.mediaBox)
        #expect(abs(first.width - PDFBuilder.pageWidth) < 0.5)
        #expect(abs(first.height - 842) < 1)
        let second = try #require(document.page(at: 2)).getBoxRect(.mediaBox)
        #expect(abs(second.height - PDFBuilder.pageWidth / 2) < 1)
    }

    @Test func rejectsEmptyScan() {
        #expect(throws: PDFBuilderError.noPages) { try PDFBuilder.makePDF(from: []) }
    }

    @Test func rendersPagesBack() throws {
        let data = try PDFBuilder.makePDF(from: [Self.testImage(width: 600, height: 800)])
        let pages = PDFPageRenderer.renderPages(of: data, scale: 1)
        #expect(pages.count == 1)
        #expect(pages.first?.width == 595)
    }
}
