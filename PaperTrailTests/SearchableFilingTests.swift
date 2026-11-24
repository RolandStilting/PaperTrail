import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PaperTrailKit
import SwiftData
import Testing
@testable import PaperTrail

/// Synthetic scan only.
@MainActor
@Suite("Filing makes scans searchable")
struct SearchableFilingTests {
    @Test func filedScanHasTheTextLayer() async throws {
        let schema = Schema(PaperTrailSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let root = FileManager.default.temporaryDirectory.appending(path: "PaperTrailTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = FilingService(location: FilingServiceRuleTests.TempLocation(url: root), store: CoordinatedFileStore())

        let context = CGContext(data: nil, width: 620, height: 877, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 620, height: 877))
        let scan = try PDFBuilder.makePDF(from: [context.makeImage()!])
        let lines = [[RecognizedLine(text: "Testmarkt kassabon 23,85", box: CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.03))]]

        let request = FilingRequest(owner: "Private", category: "Receipts", receivedDate: .now, sender: "Testmarkt", description: "Bon")
        let record = try await service.file(PendingDocument(pdfData: scan, source: .scan), request: request,
                                            extractedText: "Testmarkt kassabon 23,85", textLayer: lines, context: container.mainContext)

        let filed = try Data(contentsOf: root.appending(path: record.relativePath))
        #expect(PDFDocument(data: filed)?.string?.contains("Testmarkt kassabon") == true)
    }
}

/// Real on-device OCR on a synthetic page: the invisible text must land where the printed
/// text is, so selecting it in Preview highlights the right words.
@Suite("Vision text layer placement")
struct VisionTextLayerTests {
    @Test func ocrTextLandsOnThePrintedText() async throws {
        let width = 1240, height = 1754
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Printed text near the top left (y measured from the bottom, like PDF).
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Voorbeeld Energie Jaarnota",
                                                                       attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 120, y: 1500)
        CTLineDraw(line, context)
        let image = context.makeImage()!

        let scan = try PDFBuilder.makePDF(from: [image])
        let lines = try await VisionTextRecognizer().recognizeLines(in: [image])
        #expect(lines.first?.contains { $0.text.contains("Jaarnota") } == true)

        let searchable = try #require(SearchablePDF.addingTextLayer(to: scan, pages: lines))
        let document = try #require(PDFDocument(data: searchable))
        let page = try #require(document.page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        let found = try #require(document.findString("Jaarnota", withOptions: .caseInsensitive).first)
        let bounds = found.bounds(for: page)
        // Printed at y ≈ 1500/1754 of the page height, starting at x ≈ 120/1240.
        #expect(abs(bounds.midY / size.height - 1515.0 / 1754.0) < 0.03, "found at \(bounds)")
        #expect(bounds.minX / size.width > 0.3 && bounds.maxX / size.width < 0.8, "found at \(bounds)")
    }
}
