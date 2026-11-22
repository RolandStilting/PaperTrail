import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PDFBuilderError: LocalizedError, Equatable, Sendable {
    case noPages
    case couldNotCreateContext
    case couldNotEncodeImage(page: Int)

    public var errorDescription: String? {
        switch self {
        case .noPages:
            String(localized: "The scan has no pages. Scan the document again.", bundle: .module)
        case .couldNotCreateContext, .couldNotEncodeImage:
            String(localized: "Could not create the PDF. Try scanning again; if it keeps failing, restart the app.", bundle: .module)
        }
    }
}

/// Turns scanned page images into a single PDF. Pure Core Graphics, so it works on
/// iOS and macOS and can be tested with `swift test`.
public enum PDFBuilder {
    /// A4 width in points. Each page keeps the image's aspect ratio at this width.
    public static let pageWidth: CGFloat = 595.28

    /// - Parameter jpegQuality: Pages are JPEG-compressed so scans stay small; 0...1.
    public static func makePDF(from images: [CGImage], jpegQuality: CGFloat = 0.7) throws(PDFBuilderError) -> Data {
        guard !images.isEmpty else { throw .noPages }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw .couldNotCreateContext }

        for (index, image) in images.enumerated() {
            guard let compressed = jpegImage(from: image, quality: jpegQuality) else { throw .couldNotEncodeImage(page: index + 1) }
            let aspect = CGFloat(image.height) / CGFloat(max(image.width, 1))
            var box = CGRect(x: 0, y: 0, width: pageWidth, height: (pageWidth * aspect).rounded())
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.interpolationQuality = .high
            context.draw(compressed, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Re-encodes an image as JPEG so Core Graphics embeds it compressed (DCT) in the PDF.
    static func jpegImage(from image: CGImage, quality: CGFloat) -> CGImage? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: buffer as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Decodes image file data (JPEG, PNG, HEIC, ...) into page images. Multi-page TIFFs give several.
    public static func images(fromImageData data: Data) -> [CGImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let options = [kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        return (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, options) }
    }
}

/// Renders PDF pages to bitmaps, e.g. to OCR a PDF that has no text layer.
public enum PDFPageRenderer {
    /// - Parameter scale: Pixels per PDF point; 2 gives roughly 144 dpi, enough for OCR.
    public static func renderPages(of pdfData: Data, scale: CGFloat = 2, maxPages: Int = 50) -> [CGImage] {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider) else { return [] }
        let count = min(document.numberOfPages, maxPages)
        guard count > 0 else { return [] }
        return (1...count).compactMap { number in
            guard let page = document.page(at: number) else { return nil }
            return render(page, scale: scale)
        }
    }

    static func render(_ page: CGPDFPage, scale: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let width = Int((box.width * scale).rounded())
        let height = Int((box.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
