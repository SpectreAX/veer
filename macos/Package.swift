// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Veer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Veer", targets: ["VeerApp"]),
        .executable(name: "VeerHelper", targets: ["VeerHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        /// Config parsing, AI rule editing, validation and the Mihomo controller client. Started as
        /// a copy of Veer AI Editor's core (SpectreAX/veer-editor 6b37119); Veer builds on its own.
        .target(name: "VeerCore", dependencies: ["Yams"]),
        /// Design tokens and shared components.
        .target(name: "VeerUI", dependencies: ["VeerCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        /// What Veer and its privileged helper share: the XPC protocol, paths, signature checks.
        .target(name: "VeerHelperKit"),
        /// The root daemon that runs Mihomo for TUN. Small on purpose: no YAML, no AI.
        .executableTarget(name: "VeerHelper", dependencies: ["VeerHelperKit"]),
        /// Runs the proxy: the Mihomo process, its runtime config, profiles and the system proxy.
        .target(name: "VeerProxy", dependencies: ["VeerCore", "VeerHelperKit", "Yams"]),
        .executableTarget(
            name: "VeerApp",
            dependencies: ["VeerProxy", "VeerCore", "VeerUI", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // build-app.sh puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "VeerCoreTests", dependencies: ["VeerCore"]),
        .testTarget(name: "VeerProxyTests", dependencies: ["VeerProxy"]),
    ]
)
