// swift-tools-version: 6.0
import PackageDescription

// Arete's media playback pieces as a package any app can use: the video engine,
// the frame-accurate scrubber, the speed control, zoomable photos, and a complete
// viewer built from them.
//
// Copied from arete-apple/Packages/AreteMedia at 4e257a46. Imago's changes are in MediaViewer:
// an instant placeholder, neighbour prefetching, a back button, and trackpad swipes.
//
// The package and its folder are named ImagoMedia, not AreteMedia: Xcode identifies a local package
// by its folder name, and with Arete open in the same Xcode, two "AreteMedia" packages at different
// paths left Imago with "Missing package product". The module is still AreteMedia.
let package = Package(
    name: "ImagoMedia",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ImagoMedia", targets: ["AreteMedia"]),
    ],
    targets: [
        .target(name: "AreteMedia"),
    ]
)
