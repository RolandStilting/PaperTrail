import CoreGraphics
import Foundation
import PaperTrailKit

/// A captured document waiting for the user to confirm how to file it.
nonisolated struct PendingDocument: Identifiable, Sendable {
    let id = UUID()
    var pdfData: Data
    var source: IntakeSource
    /// The original file name for imports, shown for reference.
    var originalName: String?
    /// Page images to OCR when the PDF has no text layer; empty for text PDFs.
    var pageImages: [CGImage] = []
    /// Set when the document comes from Needs Review; filing removes it from there.
    var reviewItemURL: URL?
    /// When the document came in, if earlier than now (queued documents).
    var receivedDate: Date?
}

nonisolated enum CaptureError: LocalizedError {
    case unreadableFile(String)
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let name):
            String(localized: "Could not read \"\(name)\". Make sure the file is downloaded and not damaged, then try again.")
        case .unsupportedType(let name):
            String(localized: "\"\(name)\" is not a PDF or image. Paper Trail can import PDFs and images.")
        }
    }
}

enum DocumentCapture {
    /// Turns scanned page images into a pending PDF.
    nonisolated static func fromScan(_ pages: [CGImage]) throws -> PendingDocument {
        PendingDocument(pdfData: try PDFBuilder.makePDF(from: pages), source: .scan, pageImages: pages)
    }

    /// Reads a PDF or image picked by the user. Handles security-scoped URLs from the file importer.
    @concurrent
    nonisolated static func fromFile(at url: URL) async throws -> PendingDocument {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var readResult: Result<Data, Error> = .failure(CaptureError.unreadableFile(name))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
            readResult = Result { try Data(contentsOf: readURL) }
        }
        guard coordinationError == nil, let data = try? readResult.get() else { throw CaptureError.unreadableFile(name) }

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if type?.conforms(to: .pdf) == true || data.starts(with: Data("%PDF".utf8)) {
            return PendingDocument(pdfData: data, source: .fileImport, originalName: name)
        }
        let images = PDFBuilder.images(fromImageData: data)
        guard !images.isEmpty else { throw CaptureError.unsupportedType(name) }
        return PendingDocument(pdfData: try PDFBuilder.makePDF(from: images), source: .fileImport, originalName: name, pageImages: images)
    }
}
