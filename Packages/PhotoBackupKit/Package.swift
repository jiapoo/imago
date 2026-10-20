// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoBackupKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PhotoBackupKit", targets: ["PhotoBackupKit"]),
    ],
    targets: [
        .target(name: "PhotoBackupKit"),
        .testTarget(name: "PhotoBackupKitTests", dependencies: ["PhotoBackupKit"]),
    ]
)
