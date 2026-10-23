// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImagoKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "ImagoKit", targets: ["ImagoKit"]),
    ],
    targets: [
        .target(name: "ImagoKit"),
        .testTarget(name: "ImagoKitTests", dependencies: ["ImagoKit"]),
    ]
)
