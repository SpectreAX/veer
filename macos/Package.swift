// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Veer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Veer", targets: ["VeerApp"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        /// Config parsing, AI rule editing, validation and the Mihomo controller client. Started as
        /// a copy of Veer AI Editor's core (SpectreAX/veer-editor 6b37119); Veer builds on its own.
        .target(name: "VeerCore", dependencies: ["Yams"]),
        /// Design tokens and shared components.
        .target(name: "VeerUI", dependencies: ["VeerCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        /// Runs the proxy: the Mihomo process, its runtime config, profiles and the system proxy.
        .target(name: "VeerProxy", dependencies: ["VeerCore", "Yams"]),
        .executableTarget(
            name: "VeerApp",
            dependencies: ["VeerProxy", "VeerCore", "VeerUI"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "VeerCoreTests", dependencies: ["VeerCore"]),
        .testTarget(name: "VeerProxyTests", dependencies: ["VeerProxy"]),
    ]
)
