#if os(iOS)
import SwiftUI
import UIKit
import VisionKit

/// Wraps VisionKit's document camera. Delivers page images, or nil when the user cancels.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: (Result<[CGImage], Error>?) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: (Result<[CGImage], Error>?) -> Void

        init(onFinish: @escaping (Result<[CGImage], Error>?) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).compactMap { Self.uprightCGImage(scan.imageOfPage(at: $0)) }
            onFinish(.success(pages))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish(.failure(error))
        }

        /// CGImage ignores UIImage orientation, so redraw rotated pages upright first.
        static func uprightCGImage(_ image: UIImage) -> CGImage? {
            if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }.cgImage
        }
    }
}
#endif
