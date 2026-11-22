// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaperTrailKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PaperTrailKit", targets: ["PaperTrailKit"]),
    ],
    targets: [
        .target(
            name: "PaperTrailKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PaperTrailKitTests",
            dependencies: ["PaperTrailKit"]
        ),
    ]
)
