// swift-tools-version: 6.2
import PackageDescription

/// What the Veer iOS prototype links: the in-process Mihomo core (built by
/// ios/scripts/build-mihomo-ios.sh into Vendor/, git-ignored) behind `ProxyCore`, and Veer's
/// shared Swift code from the Mac package. Prototype only: linking Mihomo into the app is a GPL
/// exception approved for this undistributed Simulator build, see macos/docs/PLAN.md.
let package = Package(
    name: "VeerMobileKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "VeerMobileKit", targets: ["VeerMobileKit"]),
    ],
    dependencies: [
        .package(name: "Veer", path: "../../macos"),
        // Same pin as macos/Package.swift; SwiftPM resolves both to one copy.
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .binaryTarget(name: "MihomoCore", path: "Vendor/MihomoCore.xcframework"),
        .target(
            name: "VeerMobileKit",
            dependencies: [
                "MihomoCore",
                .product(name: "VeerCore", package: "Veer"),
                .product(name: "VeerProxy", package: "Veer"),
                .product(name: "Yams", package: "Yams"),
            ],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
    ]
)
