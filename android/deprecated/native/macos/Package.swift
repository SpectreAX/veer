// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VeerMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "VeerMac", targets: ["VeerMac"])],
    targets: [
        .target(name: "VeerEditor", swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .executableTarget(name: "VeerMac", dependencies: ["VeerEditor"], swiftSettings: [.defaultIsolation(MainActor.self), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .testTarget(name: "VeerEditorTests", dependencies: ["VeerEditor"]),
        .testTarget(name: "VeerMacTests", dependencies: ["VeerMac"])
    ]
)
