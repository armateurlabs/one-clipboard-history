// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneClipboardHistory",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "OneClipboardHistoryCore", targets: ["OneClipboardHistoryCore"]),
        .executable(name: "OneClipboardHistory", targets: ["OneClipboardHistoryApp"])
    ],
    dependencies: [
        // Direct-distribution builds only: the sandboxed Store variant is built by
        // the Xcode project, which does not link this product.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "OnePasteboardBridge", publicHeadersPath: "include"),
        .target(name: "OneClipboardHistoryCore", dependencies: ["CSQLite", "OnePasteboardBridge"], resources: [.process("Resources")]),
        .executableTarget(
            name: "OneClipboardHistoryApp",
            dependencies: ["OneClipboardHistoryCore", .product(name: "Sparkle", package: "Sparkle")],
            // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "OneClipboardHistoryCoreTests", dependencies: ["OneClipboardHistoryCore"]),
        .testTarget(name: "OneClipboardHistoryAppTests", dependencies: ["OneClipboardHistoryApp"])
    ]
)
