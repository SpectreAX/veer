#if os(macOS)
import Foundation
import VeerCore

/// Finds apps and what runs inside them, from the disk only: no process is started or inspected.
/// Paths are real paths (`realpath(3)`), as the kernel reports a process's executable: Foundation's
/// `resolvingSymlinksInPath` drops `/private`, which the kernel keeps.
public enum AppDiscovery {
    /// Where apps are installed, with the user's own folder. Subfolders one level down are read too
    /// (`/Applications/Utilities`, a vendor's folder), never deeper.
    public static var defaultFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["/Applications", "/System/Applications", home.appendingPathComponent("Applications").path].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The bundles in `folders` and their subfolders.
    public static func bundleURLs(in folders: [URL]) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for folder in folders {
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    found.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    found += inner.filter { $0.pathExtension == "app" }
                }
            }
        }
        return found
    }

    /// What Veer needs to route an app: its name, bundle ID, executable and helpers.
    public static func identity(ofBundle url: URL) -> AppIdentity? {
        guard let bundle = Bundle(url: url), let executable = bundle.executableURL else { return nil }
        let root = realPath(url.path)
        let info = bundle.localizedInfoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let helpers = self.helpers(in: URL(fileURLWithPath: root, isDirectory: true), main: realPath(executable.path))
        return AppIdentity(kind: .bundle, name: name, bundleID: bundle.bundleIdentifier, bundlePath: root,
                           executablePath: realPath(executable.path), helpers: helpers,
                           flavor: flavor(bundleID: bundle.bundleIdentifier, root: root, helpers: helpers))
    }

    /// A command-line tool or other bare executable, by its real path (a Homebrew link resolves to
    /// the version's own file). Nil when it is not an executable file.
    public static func identity(ofExecutable url: URL) -> AppIdentity? {
        let path = realPath(url.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return AppIdentity(kind: .executable, name: URL(fileURLWithPath: path).lastPathComponent, executablePath: path, flavor: .commandLine)
    }

    /// A picked file: a bundle, or an executable (also one inside a bundle's `Contents/MacOS`).
    public static func identity(ofPicked url: URL) -> AppIdentity? {
        if ["app", "xpc"].contains(url.pathExtension) { return identity(ofBundle: url) }
        return identity(ofExecutable: url)
    }

    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Executables inside the bundle that run as processes of their own. They are all under the
    /// bundle, so its rule covers them; the list shows the user what that covers.
    static func helpers(in bundle: URL, main: String) -> [AppIdentity.Helper] {
        let fm = FileManager.default
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        func children(_ url: URL) -> [URL] { (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] }
        var candidates: [URL] = []
        candidates += children(contents.appendingPathComponent("MacOS"))
        candidates += children(contents.appendingPathComponent("Helpers"))
        candidates += children(contents.appendingPathComponent("XPCServices"))
        candidates += children(contents.appendingPathComponent("Library/LoginItems"))
        candidates += children(contents.appendingPathComponent("Library/LaunchServices"))
        for item in children(contents.appendingPathComponent("Frameworks")) {
            if item.pathExtension == "app" { candidates.append(item); continue }
            guard item.pathExtension == "framework" else { continue }
            for version in children(item.appendingPathComponent("Versions")) where version.lastPathComponent != "Current" {
                candidates += children(version.appendingPathComponent("Helpers"))
                candidates += children(version.appendingPathComponent("XPCServices"))
            }
        }
        var seen: Set<String> = [main]
        var helpers: [AppIdentity.Helper] = []
        for candidate in candidates where helpers.count < 64 {
            let executable: URL? = ["app", "xpc"].contains(candidate.pathExtension) ? Bundle(url: candidate)?.executableURL : candidate
            guard let executable else { continue }
            let path = realPath(executable.path)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, fm.isExecutableFile(atPath: path),
                  seen.insert(path).inserted else { continue }
            let name = ["app", "xpc"].contains(candidate.pathExtension) ? candidate.deletingPathExtension().lastPathComponent : candidate.lastPathComponent
            helpers.append(AppIdentity.Helper(name: name, path: path))
        }
        return helpers
    }

    static func flavor(bundleID: String?, root: String, helpers: [AppIdentity.Helper]) -> AppIdentity.Flavor {
        if bundleID == "com.apple.Safari" || bundleID?.hasPrefix("com.apple.SafariTechnologyPreview") == true { return .webKit }
        if root.hasPrefix("/System/") { return .system }
        if FileManager.default.fileExists(atPath: root + "/Contents/Frameworks/Electron Framework.framework") { return .electron }
        if helpers.contains(where: { $0.path.contains(".framework/Versions/") && $0.name.contains("Helper") }) { return .chromium }
        return .native
    }
}

/// Discovered apps kept on disk (`cache/apps.json`), so opening the list does not walk every
/// bundle again: a bundle is read again only when its `Info.plist` changed.
public final class AppCatalogStore: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        let stamp: Double
        let app: AppIdentity
    }

    private let file: URL
    private let lock = NSLock()

    public init(paths: VeerPaths) {
        file = paths.root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("apps.json")
    }

    /// What the last scan found, without touching the bundles.
    public func cached() -> [AppIdentity] {
        lock.withLock { load().values.map(\.app).sorted(by: Self.order) }
    }

    /// Lists the folders and reads only the bundles that are new or changed since the last scan.
    public func scan(folders: [URL] = AppDiscovery.defaultFolders) -> [AppIdentity] {
        let previous = lock.withLock { load() }
        var entries: [String: Entry] = [:]
        for url in AppDiscovery.bundleURLs(in: folders) {
            let path = url.path
            let stamp = Self.stamp(of: url)
            if let old = previous[path], old.stamp == stamp {
                entries[path] = old
            } else if let app = AppDiscovery.identity(ofBundle: url) {
                entries[path] = Entry(stamp: stamp, app: app)
            }
        }
        lock.withLock { save(entries) }
        return entries.values.map(\.app).sorted(by: Self.order)
    }

    /// One bundle (a running app outside the usual folders), through the same cache.
    public func identity(ofBundle url: URL) -> AppIdentity? {
        let stamp = Self.stamp(of: url)
        if let entry = lock.withLock({ load()[url.path] }), entry.stamp == stamp { return entry.app }
        return AppDiscovery.identity(ofBundle: url)
    }

    static func order(_ lhs: AppIdentity, _ rhs: AppIdentity) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    static func stamp(of bundle: URL) -> Double {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let attributes = try? FileManager.default.attributesOfItem(atPath: plist.path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    private func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func save(_ entries: [String: Entry]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}
#endif
