// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChatUI",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "ChatUI", targets: ["ChatUI"])
    ],
    dependencies: [
        .package(path: "../ChatCore")
    ],
    targets: [
        .target(name: "ChatUI", dependencies: ["ChatCore"])
    ]
)
