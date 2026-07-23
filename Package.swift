// swift-tools-version:5.1
import PackageDescription

// Android fork (Ceylo/Kingfisher @ android). Additive #if guards only; the Apple
// build is unchanged. On Android the SwiftUI/UIKit/AppKit layers are guarded off
// and KFCrossPlatformImage is a Data-backed stub — SkipUI's Bitmap-backed UIImage
// needs CJNI, which a plain SwiftPM package can't have, so the pure-Swift
// downloader/cache traffic in Data and the app module decodes for display.
let package = Package(
    name: "Kingfisher",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "Kingfisher", targets: ["Kingfisher"])
    ],
    targets: [
        .target(
            name: "Kingfisher",
            path: "Sources",
            exclude: ["Documentation.docc"]
        )
    ]
)
