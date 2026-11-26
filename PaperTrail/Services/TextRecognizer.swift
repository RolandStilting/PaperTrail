import CoreGraphics
import Foundation
import PDFKit
import PaperTrailKit
import Vision

/// Text found on a document, and for scans where each line was found (for the PDF's
/// invisible text layer).
nonisolated struct ExtractedText: Sendable {
    var text: String
    /// Lines per page with their place on the page; nil when the PDF already had text.
    var lines: [[RecognizedLine]]?
}

nonisolated protocol TextRecognizing: Sendable {
    /// Recognised lines of each page, with their position on the page.
    func recognizeLines(in pages: [CGImage]) async throws -> [[RecognizedLine]]
}

extension TextRecognizing {
    /// All pages as text, pages separated by blank lines.
    func recognizeText(in pages: [CGImage]) async throws -> ExtractedText {
        let lines = try await recognizeLines(in: pages)
        return ExtractedText(text: Self.text(of: lines), lines: lines)
    }

    nonisolated static func text(of pages: [[RecognizedLine]]) -> String {
        pages.map(RecognizedLine.readingOrderText).joined(separator: "\n\n")
    }
}

/// On-device OCR with Vision. Document content never leaves the device.
nonisolated struct VisionTextRecognizer: TextRecognizing {
    var languages: [Locale.Language] = [Locale.Language(identifier: "nl-NL"), Locale.Language(identifier: "en-US")]

    @concurrent
    func recognizeLines(in pages: [CGImage]) async throws -> [[RecognizedLine]] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        var result: [[RecognizedLine]] = []
        for page in pages {
            try Task.checkCancellation()
            let observations = try await request.perform(on: page)
            // Bounding boxes are normalized with the origin at the lower left, like PDF pages.
            result.append(observations.compactMap { observation in
                observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, box: observation.boundingBox.cgRect) }
            })
        }
        return result
    }
}

/// Gets text out of a PDF: the embedded text layer when there is one, OCR otherwise.
nonisolated struct PDFTextExtractor: Sendable {
    var recognizer: any TextRecognizing
    /// Below this many non-whitespace characters the PDF is treated as a scan without text.
    var minimumEmbeddedCharacters = 20

    @concurrent
    func extract(from pdfData: Data) async throws -> ExtractedText {
        if let embedded = PDFDocument(data: pdfData)?.string,
           embedded.filter({ !$0.isWhitespace }).count >= minimumEmbeddedCharacters {
            return ExtractedText(text: embedded, lines: nil)
        }
        return try await recognizer.recognizeText(in: PDFPageRenderer.renderPages(of: pdfData))
    }

    func extractText(from pdfData: Data) async throws -> String {
        try await extract(from: pdfData).text
    }
}
