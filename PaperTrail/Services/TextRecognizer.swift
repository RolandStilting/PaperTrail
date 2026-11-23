import CoreGraphics
import Foundation
import PDFKit
import PaperTrailKit
import Vision

nonisolated protocol TextRecognizing: Sendable {
    /// Returns the recognised text of all pages, pages separated by blank lines.
    func recognizeText(in pages: [CGImage]) async throws -> String
}

/// On-device OCR with Vision. Document content never leaves the device.
nonisolated struct VisionTextRecognizer: TextRecognizing {
    var languages: [Locale.Language] = [Locale.Language(identifier: "nl-NL"), Locale.Language(identifier: "en-US")]

    @concurrent
    func recognizeText(in pages: [CGImage]) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        var pageTexts: [String] = []
        for page in pages {
            try Task.checkCancellation()
            let observations = try await request.perform(on: page)
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            pageTexts.append(lines.joined(separator: "\n"))
        }
        return pageTexts.joined(separator: "\n\n")
    }
}

/// Gets text out of a PDF: the embedded text layer when there is one, OCR otherwise.
nonisolated struct PDFTextExtractor: Sendable {
    var recognizer: any TextRecognizing
    /// Below this many non-whitespace characters the PDF is treated as a scan without text.
    var minimumEmbeddedCharacters = 20

    @concurrent
    func extractText(from pdfData: Data) async throws -> String {
        if let embedded = PDFDocument(data: pdfData)?.string,
           embedded.filter({ !$0.isWhitespace }).count >= minimumEmbeddedCharacters {
            return embedded
        }
        return try await recognizer.recognizeText(in: PDFPageRenderer.renderPages(of: pdfData))
    }
}
