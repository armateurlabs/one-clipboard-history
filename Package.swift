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
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "OnePasteboardBridge", publicHeadersPath: "include"),
        .target(name: "OneClipboardHistoryCore", dependencies: ["CSQLite", "OnePasteboardBridge"], resources: [.process("Resources")]),
        .executableTarget(name: "OneClipboardHistoryApp", dependencies: ["OneClipboardHistoryCore"]),
        .testTarget(name: "OneClipboardHistoryCoreTests", dependencies: ["OneClipboardHistoryCore"]),
        .testTarget(name: "OneClipboardHistoryAppTests", dependencies: ["OneClipboardHistoryApp"])
    ]
)
