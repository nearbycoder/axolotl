// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AxolotlKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AxolotlKit", targets: ["AxolotlKit"]),
    ],
    targets: [
        .target(name: "AxolotlKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "AxolotlKitTests", dependencies: ["AxolotlKit"]),
    ]
)
