// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Veer",
    // iOS is only for the Simulator prototype in ../ios, which links the two libraries below.
    platforms: [.macOS(.v14), .iOS(.v26)],
    products: [
        .executable(name: "Veer", targets: ["VeerApp"]),
        .executable(name: "VeerHelper", targets: ["VeerHelper"]),
        .library(name: "VeerCore", targets: ["VeerCore"]),
        .library(name: "VeerProxy", targets: ["VeerProxy"]),
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
        .target(name: "VeerUI", dependencies: ["VeerCore"], exclude: ["CLAUDE.md"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        /// What Veer and its privileged helper share: the XPC protocol, paths, signature checks.
        .target(name: "VeerHelperKit"),
        /// The root daemon that runs Mihomo for TUN. Small on purpose: no YAML, no AI.
        .executableTarget(name: "VeerHelper", dependencies: ["VeerHelperKit"]),
        /// Runs the proxy: the Mihomo process, its runtime config, profiles and the system proxy.
        /// On iOS only the parts without a process, the helper or the system proxy are built.
        .target(
            name: "VeerProxy",
            dependencies: ["VeerCore", .target(name: "VeerHelperKit", condition: .when(platforms: [.macOS])), "Yams"],
            exclude: ["CLAUDE.md"]
        ),
        .executableTarget(
            name: "VeerApp",
            dependencies: ["VeerProxy", "VeerCore", "VeerUI", .product(name: "Sparkle", package: "Sparkle")],
            exclude: ["Agent/CLAUDE.md"],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // build-app.sh puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "VeerCoreTests", dependencies: ["VeerCore"]),
        .testTarget(name: "VeerProxyTests", dependencies: ["VeerProxy"]),
        .testTarget(name: "VeerUITests", dependencies: ["VeerUI"]),
        .testTarget(name: "VeerAppTests", dependencies: ["VeerApp"]),
    ]
)
