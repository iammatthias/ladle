// swift-tools-version: 6.0
import PackageDescription

// The protocol core, free of UIKit and SwiftUI so `swift test` runs it on the Mac. iOS 27.0 is a
// floor, not the app's target: the LadleShots renderer runs on this Mac, whose iOS support
// version is 27.0, and a package cannot require more than its consumers.
let package = Package(
    name: "ApronKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
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
        // Runs the real Rust server (aprond); skips without its binary unless
        // APRON_REQUIRE_SERVER=1.
        .testTarget(
            name: "ApronKitIntegrationTests",
            dependencies: ["ApronKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
