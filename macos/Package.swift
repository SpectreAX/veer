// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Veer",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Veer", targets: ["VeerApp"])],
    dependencies: [
        // Shared with Veer AI Editor (SpectreAX/veer-editor): config parsing, AI editing, the
        // controller client and the design system. A checkout next to this repository
        // (…/veer-editor beside …/veer-app) while both change together.
        .package(path: "../../veer-editor"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        /// Runs the proxy: the Mihomo process, its runtime config, profiles and the system proxy.
        .target(name: "VeerProxy", dependencies: [.product(name: "VeerCore", package: "veer-editor"), "Yams"]),
        .executableTarget(
            name: "VeerApp",
            dependencies: ["VeerProxy", .product(name: "VeerCore", package: "veer-editor"), .product(name: "VeerUI", package: "veer-editor")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "VeerProxyTests", dependencies: ["VeerProxy"]),
    ]
)
