// swift-tools-version:6.0
import PackageDescription

// Android fork (Ceylo/Kingfisher @ android). Additive `#if os(Android)` guards only;
// the Apple build is unchanged. `canImport(...)` is deliberately *not* used for the
// frameworks we guard: a module of that name anywhere in Skip's shared Modules
// directory answers `canImport` for every target — see the FurAffinity repo's
// Android/docs/build-and-run.md § Module-name poisoning.
//
// On Android, `KFCrossPlatformImage` is SkipSwiftUI's Bitmap-backed `UIImage` and every
// decode goes through the five entry points in Sources/Image/Image.swift. Reaching that
// type pulls CJNI, which a plain SwiftPM package cannot resolve — hence the skipstone
// plugin and the *unconditional* SkipFuseUI dependency below.
//
// `Sources/Documentation.docc` is deleted rather than excluded: skipstone walks the
// whole target directory (it honors neither `sources:` nor `exclude:`) and generates a
// Kotlin bridge for every SwiftUI `View` it finds — including the tutorial snippets,
// whose repeated `ContentView` steps then collide as redeclarations. `#if` around them
// does not help; the bridge generator does not evaluate it.
let package = Package(
    name: "Kingfisher",
    platforms: [.iOS(.v18), .macOS(.v14), .tvOS(.v17), .watchOS(.v10), .macCatalyst(.v17)],
    products: [
        .library(name: "Kingfisher", targets: ["Kingfisher"])
    ],
    dependencies: [
        // Exact, and equal to the FurAffinity manifests': a floating pin silently drifts
        // past the installed `skip` CLI.
        .package(url: "https://source.skip.tools/skip.git", exact: "1.9.4"),
        .package(url: "https://github.com/Ceylo/skip-fuse-ui.git", branch: "android"),
        .package(url: "https://github.com/Ceylo/skip-ui.git", branch: "android"),
    ],
    targets: [
        .target(
            name: "Kingfisher",
            dependencies: [
                // Unconditional on purpose: SKIP_BRIDGE is unset in the pass that runs
                // plugins, so gating this edge makes skipstone emit a stub
                // build.gradle.kts and Gradle dies on "Unresolved reference 'android'".
                .product(name: "SkipFuseUI", package: "skip-fuse-ui"),
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [.plugin(name: "skipstone", package: "skip")]
        )
    ]
)

// Android build only. All library types must be dynamic to support bridging — and
// Kingfisher carries process globals (`KingfisherManager.shared`, `ImageCache.default`,
// `ImageDownloader.default`, `NetworkMonitor.default`), so a static link would give the
// app one copy per `.so`. See the FurAffinity repo's Android/docs/shared-sources.md
// § One module, one image.
if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    package.products = package.products.map { product in
        guard let library = product as? Product.Library else { return product }
        return .library(name: library.name, type: .dynamic, targets: library.targets)
    }
}
