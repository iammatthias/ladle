// swift-tools-version: 6.0
import PackageDescription

// The protocol core, free of UIKit and SwiftUI so `swift test` runs it on the Mac.
let package = Package(
    name: "ApronKit",
    platforms: [.iOS("27.1"), .macOS("27.0")],
    products: [
        .library(name: "ApronKit", targets: ["ApronKit"]),
    ],
    targets: [
        .target(
            name: "ApronKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ApronKitTests",
            dependencies: ["ApronKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
