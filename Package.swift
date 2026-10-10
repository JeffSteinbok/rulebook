// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rulebook",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RulebookKit", targets: ["RulebookKit"]),
        // A stateful fake of the Graph endpoints the app uses, for tests in
        // this package and in the app. Never linked into the shipping app.
        .library(name: "RulebookTesting", targets: ["RulebookTesting"]),
        .executable(name: "rulebook", targets: ["rulebook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Pure Swift + Foundation only. No UIKit/SwiftUI/AppKit imports here,
        // so this target builds unchanged for macOS CLI, iOS, and the Simulator.
        .target(name: "RulebookKit"),
        .target(name: "RulebookTesting", dependencies: ["RulebookKit"]),
        .executableTarget(
            name: "rulebook",
            dependencies: [
                "RulebookKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Hermetic: no network, no account, no credentials.
        .testTarget(
            name: "RulebookKitTests",
            dependencies: ["RulebookKit", "RulebookTesting"],
            resources: [.copy("Fixtures")]
        ),
        // Talks to a real mailbox. Skipped unless RULEBOOK_LIVE=1, and kept in
        // its own target so the default suite cannot accidentally depend on it.
        .testTarget(
            name: "RulebookLiveTests",
            dependencies: ["RulebookKit", "RulebookTesting"]
        ),
    ]
)
