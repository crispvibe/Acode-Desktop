// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChatCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "ChatCore", targets: ["ChatCore"])
    ],
    targets: [
        .target(name: "ChatCore"),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"])
    ]
)
