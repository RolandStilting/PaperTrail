import CoreGraphics
import Foundation
import PDFKit
import PaperTrailKit
import Vision

/// Looks on a filed bill for a payment code the sender put there: a QR code on the pages,
/// a link annotation, or a link in the text. Runs on the device only.
nonisolated enum PaymentCodeScanner {
    enum ScanError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "Couldn't read \(name) to look for a payment code. Check that the file is in iCloud Drive and try again.")
            }
        }
    }

    /// At most this many pages are searched; payment codes sit on the first pages.
    static let maxPages = 3

    struct Result: Sendable {
        var code: PaymentCode?
        /// The QR search could not run (e.g. Vision's barcode detector is unavailable, as in
        /// the Simulator). Links were still searched; search again later for QR codes.
        var qrSearchFailed: Bool
    }

    @concurrent
    static func scan(fileAt url: URL, text: String) async throws -> Result {
        let data = try coordinatedRead(url)
        var qrPayloads: [String] = []
        var qrSearchFailed = false
        do {
            qrPayloads = try await qrCodes(in: PDFPageRenderer.renderPages(of: data, scale: 2, maxPages: maxPages))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            qrSearchFailed = true
        }
        let code = PaymentCode.find(qrPayloads: qrPayloads, links: linkAnnotations(in: data), text: text)
        return Result(code: code, qrSearchFailed: qrSearchFailed)
    }

    static func qrCodes(in pages: [CGImage]) async throws -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        var payloads: [String] = []
        for page in pages {
            try Task.checkCancellation()
            payloads += try await request.perform(on: page).compactMap(\.payloadString)
        }
        return payloads
    }

    static func linkAnnotations(in data: Data) -> [URL] {
        guard let document = PDFDocument(data: data) else { return [] }
        var urls: [URL] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            urls += page.annotations.compactMap(\.url)
        }
        return urls
    }

    /// Reads through the file coordinator, which also waits for iCloud to download the file.
    private static func coordinatedRead(_ url: URL) throws -> Data {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var result: Swift.Result<Data, Error> = .failure(ScanError.unreadable(url.lastPathComponent))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Swift.Result { try Data(contentsOf: readURL) }
        }
        if coordinationError != nil { throw ScanError.unreadable(url.lastPathComponent) }
        return try result.get()
    }
}
