import CoreGraphics
import PaperTrailKit
import SwiftUI

/// A small preview of a document's first page. Only for files already on this device, so a
/// list never downloads the whole archive from iCloud; others show a document symbol.
struct DocumentThumbnail: View {
    let url: URL?
    var size = CGSize(width: 34, height: 44)

    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .scaledToFit()
                    .background(.white)
                    .clipShape(.rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator, lineWidth: 0.5))
            } else {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { return }
        let key = url.path(percentEncoded: false) as NSString
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            image = cached.image
            return
        }
        guard Self.isOnDevice(url) else { return }
        let pixelWidth = size.width * displayScale
        let rendered: CGImage? = await Task.detached(priority: .utility) {
            guard let data = try? InboxCollector.coordinatedRead(url),
                  let provider = CGDataProvider(data: data as CFData),
                  let page = CGPDFDocument(provider)?.page(at: 1) else { return nil }
            let width = page.getBoxRect(.cropBox).width
            return PDFPageRenderer.renderPages(of: data, scale: width > 0 ? pixelWidth / width : 0.1, maxPages: 1).first
        }.value
        if let rendered {
            ThumbnailCache.shared.setObject(ThumbnailBox(image: rendered), forKey: key)
            image = rendered
        }
    }

    /// True for local files and iCloud files that are downloaded.
    static func isOnDevice(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        return status == nil || status == .current
    }
}

/// Rendered thumbnails for this session; filed PDFs don't change, so the path is the key.
final class ThumbnailBox {
    let image: CGImage
    init(image: CGImage) { self.image = image }
}

enum ThumbnailCache {
    nonisolated(unsafe) static let shared: NSCache<NSString, ThumbnailBox> = {
        let cache = NSCache<NSString, ThumbnailBox>()
        cache.countLimit = 500
        return cache
    }()
}
