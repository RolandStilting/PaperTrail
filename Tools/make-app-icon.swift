// Makes every app icon size from Tools/AppIcon-source.png and writes the AppIcon set.
// Run from the repository root:  swift Tools/make-app-icon.swift
//
// The source may have a white border and rounded corners (as exported from most design
// tools). The script finds the coloured square, crops just inside its rounded corners for
// iOS (the system rounds the corners itself and needs an opaque square), and draws the Mac
// version as a rounded square with transparent margins, like other Mac app icons.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sourceURL = URL(fileURLWithPath: "Tools/AppIcon-source.png")
let setURL = URL(fileURLWithPath: "PaperTrail/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fatalError("Could not read \(sourceURL.path). Save the icon there as a PNG.")
}

// Read the pixels as RGBA so the border can be measured.
let width = source.width, height = source.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let reader = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                       space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
reader.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

/// Pixel at (x, y) with y counted from the top.
func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let i = ((height - 1 - y) * width + x) * 4
    return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
}
func isBorder(_ x: Int, _ y: Int) -> Bool {
    let p = pixel(x, y)
    return p.r > 225 && p.g > 225 && p.b > 225
}

// The coloured square: first non-white pixel from each side along the middle lines.
let midX = width / 2, midY = height / 2
let left = (0..<width).first { !isBorder($0, midY) } ?? 0
let right = (0..<width).reversed().first { !isBorder($0, midY) } ?? width - 1
let top = (0..<height).first { !isBorder(midX, $0) } ?? 0
let bottom = (0..<height).reversed().first { !isBorder(midX, $0) } ?? height - 1

// Corner radius from how far the diagonal from the top-left corner runs through white:
// for a rounded corner that distance (per axis) is r × (1 − 1/√2).
let diagonal = (0..<min(right - left, bottom - top)).first { !isBorder(left + $0, top + $0) } ?? 0
let radius = Double(diagonal) / (1 - 1 / 2.squareRoot())
// Crop inside the corners, with a small safety margin for anti-aliasing.
let inset = Int((radius * (1 - 1 / 2.squareRoot())).rounded(.up)) + 6
let side = min(right - left, bottom - top) - 2 * inset
let crop = CGRect(x: left + inset, y: top + inset, width: side, height: side)
let background = pixel(left + inset + 4, midY)
print("Coloured square \(left)…\(right) × \(top)…\(bottom), corner radius ≈ \(Int(radius)) px, crop \(side) px from (\(left + inset), \(top + inset))")

guard let square = source.cropping(to: crop) else { fatalError("Crop failed") }

func render(size: Int, mac: Bool) -> CGImage {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                      bitmapInfo: mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.interpolationQuality = .high
    let s = CGFloat(size)
    var body = CGRect(x: 0, y: 0, width: s, height: s)
    if mac {
        // Apple's Mac icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
        c.clear(body)
        body = body.insetBy(dx: s * 100 / 1024, dy: s * 100 / 1024)
        c.addPath(CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil))
        c.clip()
    }
    c.setFillColor(CGColor(srgbRed: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255, blue: CGFloat(background.b) / 255, alpha: 1))
    c.fill(body)
    // The crop fills the whole icon: shrinking it would show a seam, because the background
    // colour of the source isn't perfectly even.
    c.draw(square, in: body)
    return c.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = setURL.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

// Start from an empty set so no old images stay behind.
try? FileManager.default.removeItem(at: setURL)
try FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)

var images: [[String: Any]] = []
let ios = render(size: 1024, mac: false)
write(ios, "ios-1024.png")
images.append(["filename": "ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = "mac-\(points)@\(factor)x.png"
        write(render(size: points * factor, mac: true), name)
        images.append(["filename": name, "idiom": "mac", "scale": "\(factor)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: setURL.appendingPathComponent("Contents.json"))

// Check: the iOS icon must have no white left in its corners.
var check = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
let checker = CGContext(data: &check, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 1024 * 4, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
checker.draw(ios, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let whiteCorners = [(0, 0), (1023, 0), (0, 1023), (1023, 1023), (3, 3), (1020, 1020)].filter { x, y in
    let i = (y * 1024 + x) * 4
    return check[i] > 225 && check[i + 1] > 225 && check[i + 2] > 225
}
print(whiteCorners.isEmpty ? "iOS icon corners are clean." : "Warning: white left in corners \(whiteCorners)")
print("Wrote \(images.count) icons to \(setURL.path)")
