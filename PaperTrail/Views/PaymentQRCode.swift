import CoreImage
import CoreImage.CIFilterBuiltins
import PaperTrailKit
import SwiftUI

/// Renders an EPC payment QR code. Error correction level M, as the EPC standard asks.
struct PaymentQRCode: View {
    let payload: String

    var body: some View {
        if let image = Self.render(payload) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(Text("Payment QR code"))
        } else {
            Label("Could not make the QR code. Use the copy buttons instead.", systemImage: "exclamationmark.triangle")
        }
    }

    static func render(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
