// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mcm",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MCMCore", targets: ["MCMCore"]),
        .executable(name: "mcm", targets: ["MCMApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "MPasteboardBridge", publicHeadersPath: "include"),
        .target(name: "MCMCore", dependencies: ["CSQLite", "MPasteboardBridge"]),
        .executableTarget(name: "MCMApp", dependencies: ["MCMCore"]),
        .testTarget(name: "MCMCoreTests", dependencies: ["MCMCore"]),
        .testTarget(name: "MCMAppTests", dependencies: ["MCMApp"])
    ]
)
