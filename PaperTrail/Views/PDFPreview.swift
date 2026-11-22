import PDFKit
import SwiftUI

#if os(iOS)
struct PDFPreview: UIViewRepresentable {
    var data: Data

    func makeUIView(context: Context) -> PDFView { Self.makeView() }
    func updateUIView(_ view: PDFView, context: Context) { Self.update(view, data: data) }
}
#else
struct PDFPreview: NSViewRepresentable {
    var data: Data

    func makeNSView(context: Context) -> PDFView { Self.makeView() }
    func updateNSView(_ view: PDFView, context: Context) { Self.update(view, data: data) }
}
#endif

extension PDFPreview {
    static func makeView() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    static func update(_ view: PDFView, data: Data) {
        // A pending document's bytes never change, so load once.
        if view.document == nil {
            view.document = PDFDocument(data: data)
        }
    }
}
