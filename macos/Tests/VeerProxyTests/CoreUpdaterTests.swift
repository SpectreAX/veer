import CryptoKit
import Foundation
import Testing
import VeerCore
@testable import VeerProxy

struct CoreUpdaterTests {
    private func answer(tag: String = "v1.19.33", name: String? = nil, url: String? = nil, digest: String? = "sha256:abc") -> Data {
        let file = name ?? "mihomo-darwin-arm64-\(tag).gz"
        let link = url ?? "\(CoreUpdater.assetPrefix)\(tag)/\(file)"
        let older = "{\"name\":\"mihomo-darwin-arm64-go120-\(tag).gz\",\"browser_download_url\":\"\(link)-old\",\"digest\":\"sha256:old\"}"
        let digestField = digest.map { ",\"digest\":\"\($0)\"" } ?? ""
        let text = "{\"tag_name\":\"\(tag)\",\"assets\":[\(older),{\"name\":\"\(file)\",\"browser_download_url\":\"\(link)\"\(digestField)}]}"
        return Data(text.utf8)
    }

    @Test func picksThePlainAssetForThisMac() throws {
        let release = try CoreUpdater.parse(answer(), architecture: "arm64")
        #expect(release.version == "v1.19.33")
        #expect(release.asset.lastPathComponent == "mihomo-darwin-arm64-v1.19.33.gz")
        #expect(release.sha256 == "abc")
    }

    @Test func refusesWhatItCantCheckOrDidNotComeFromUpstream() {
        #expect(throws: EditorError.self) { try CoreUpdater.parse(answer(digest: nil), architecture: "arm64") }
        #expect(throws: EditorError.self) { try CoreUpdater.parse(answer(url: "https://example.com/mihomo.gz"), architecture: "arm64") }
        #expect(throws: EditorError.self) { try CoreUpdater.parse(answer(), architecture: "amd64") }
        #expect(throws: EditorError.self) { try CoreUpdater.parse(Data("no".utf8), architecture: "arm64") }
    }

    @Test func comparesVersionsAsNumbers() {
        #expect(CoreUpdater.isNewer("v1.19.33", than: "v1.19.29"))
        #expect(CoreUpdater.isNewer("v1.20.0", than: "v1.19.33"))
        #expect(CoreUpdater.isNewer("v1.19.100", than: "v1.19.33"))
        #expect(!CoreUpdater.isNewer("v1.19.33", than: "v1.19.33"))
        #expect(!CoreUpdater.isNewer("v1.19.3", than: "v1.19.29"))
        #expect(!CoreUpdater.isNewer("alpha", than: "v1.19.29"))
        #expect(CoreUpdater.isNewer("v1.19.33", than: nil))
    }

    // MARK: Installing, with a shell script in place of the core and no network

    private func folder() throws -> VeerPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VeerPaths(root: root)
    }

    /// A gzipped script that answers `-v` as Mihomo does, and its digest.
    private func package(version: String, exit status: Int = 0) throws -> (data: Data, sha256: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("veer-pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("mihomo")
        try "#!/bin/sh\necho 'Mihomo Meta \(version) darwin arm64 with go1.24'\nexit \(status)\n".write(to: file, atomically: true, encoding: .utf8)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [file.path]
        try gzip.run()
        gzip.waitUntilExit()
        let data = try Data(contentsOf: folder.appendingPathComponent("mihomo.gz"))
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func release(_ version: String, _ sha256: String) -> CoreRelease {
        CoreRelease(version: version, asset: URL(string: "https://example.invalid/m.gz")!, sha256: sha256)
    }

    @Test func installsAndReplacesAndRemoves() async throws {
        let updater = CoreUpdater(paths: try folder())
        #expect(!updater.hasInstalled)
        let first = try package(version: "v1.19.33")
        try await updater.install(release("v1.19.33", first.sha256)) { _ in first.data }
        #expect(updater.hasInstalled)
        #expect(await CoreUpdater.version(of: updater.installed) == "v1.19.33")
        let second = try package(version: "v1.19.34")
        try await updater.install(release("v1.19.34", second.sha256)) { _ in second.data }
        #expect(await CoreUpdater.version(of: updater.installed) == "v1.19.34")
        try updater.remove()
        #expect(!updater.hasInstalled)
    }

    /// Each way a download can be wrong leaves the core that was there, and no working files.
    @Test func aBadDownloadChangesNothing() async throws {
        let updater = CoreUpdater(paths: try folder())
        let good = try package(version: "v1.19.33")
        try await updater.install(release("v1.19.33", good.sha256)) { _ in good.data }

        let tampered = try package(version: "v1.19.34")
        await #expect(throws: EditorError.self) {
            try await updater.install(release("v1.19.34", good.sha256)) { _ in tampered.data }
        }
        let wrong = try package(version: "v1.19.99")
        await #expect(throws: EditorError.self) {
            try await updater.install(release("v1.19.34", wrong.sha256)) { _ in wrong.data }
        }
        let broken = try package(version: "v1.19.34", exit: 3)
        await #expect(throws: EditorError.self) {
            try await updater.install(release("v1.19.34", broken.sha256)) { _ in broken.data }
        }
        let junk = Data("not gzip".utf8), junkDigest = SHA256.hash(data: junk).map { String(format: "%02x", $0) }.joined()
        await #expect(throws: EditorError.self) {
            try await updater.install(release("v1.19.34", junkDigest)) { _ in junk }
        }

        #expect(await CoreUpdater.version(of: updater.installed) == "v1.19.33")
        let left = try FileManager.default.contentsOfDirectory(atPath: updater.installed.deletingLastPathComponent().path)
        #expect(left == ["mihomo"])
    }

    @Test func aMissingOrBrokenBinaryHasNoVersion() async throws {
        let paths = try folder()
        #expect(await CoreUpdater.version(of: paths.root.appendingPathComponent("nothing")) == nil)
    }
}
