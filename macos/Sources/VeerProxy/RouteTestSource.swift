import CryptoKit
import Foundation
import VeerCore
import Yams

/// What the route tester checks against: the rules and rule sets of the config the core runs, and
/// the core's own geodata and rule-set files in its home. Nothing is downloaded; what is missing is
/// reported as missing.
public struct RouteTestSource: Sendable {
    /// What was read, for the page to say.
    public struct Inputs: Sendable, Equatable {
        /// File names of the GeoSite and GeoIP data used; nil when there was none.
        public var geosite: String?
        public var geoip: String?
        /// Rule-provider names Veer read, and those it could not.
        public var readable: [String] = []
        public var unreadable: [String] = []
    }

    public let rules: [String]
    public let data: RouteData
    public let inputs: Inputs

    /// The largest rule-set file read; a bigger one is left unread.
    static let maxFileSize = 32 << 20

    /// `config`: the YAML the core runs, or would run. `home`: the core's folder.
    public static func load(config: String, home: URL, fallback: GeoDataStore? = nil) async -> RouteTestSource {
        let source = withoutGeodata(config: config, home: home)
        var data = source.data, inputs = source.inputs
        (data.geosite, inputs.geosite) = await geosite(home: home, fallback: fallback)
        let geodataMode = (try? Yams.compose(yaml: config))?.mapping?[Node("geodata-mode")]?.bool ?? false
        (data.countries, inputs.geoip) = await countries(home: home, geodataMode: geodataMode, fallback: fallback)
        return RouteTestSource(rules: source.rules, data: data, inputs: inputs)
    }

    /// The rules and rule sets alone, for a second config checked against geodata already loaded
    /// (the route preview reads a profile before and after a change).
    public static func withoutGeodata(config: String, home: URL) -> RouteTestSource {
        let rules = (try? ConfigDocument.parse(config).rules) ?? []
        var inputs = Inputs()
        var ruleSets: [String: RuleSetContents] = [:]
        if case .mapping(let providers)? = (try? Yams.compose(yaml: config))?.mapping?[Node("rule-providers")] {
            for (key, value) in providers {
                guard let name = key.string else { continue }
                if let contents = contents(of: value.mapping, home: home) {
                    ruleSets[name] = contents
                    inputs.readable.append(name)
                } else {
                    inputs.unreadable.append(name)
                }
            }
        }
        return RouteTestSource(rules: rules, data: RouteData(ruleSets: ruleSets), inputs: inputs)
    }

    // MARK: Rule sets

    /// A provider's contents: a MetaCubeX list looked up in the geodata, the inline payload, or the
    /// file the core downloaded. nil when none of these can be read (an MRS file is binary).
    static func contents(of provider: Node.Mapping?, home: URL) -> RuleSetContents? {
        guard let provider else { return nil }
        let url = provider[Node("url")]?.string
        if let url, let set = MetaCubeXSet(url: url) {
            return set.kind == "geosite" ? .geosite(set.name) : .geoip(set.name)
        }
        let behavior = provider[Node("behavior")]?.string?.lowercased() ?? "classical"
        if case .sequence(let payload)? = provider[Node("payload")] {
            return contents(payload.compactMap(\.string), behavior: behavior)
        }
        let format = provider[Node("format")]?.string?.lowercased() ?? "yaml"
        guard format != "mrs", let file = file(path: provider[Node("path")]?.string, url: url, home: home),
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return contents(entries(in: text, format: format), behavior: behavior)
    }

    static func contents(_ entries: [String], behavior: String) -> RuleSetContents? {
        switch behavior {
        case "domain": .domains(entries)
        case "ipcidr": .cidrs(entries)
        case "classical": .classical(entries)
        default: nil
        }
    }

    /// The provider's file inside `home`: its `path`, or where Mihomo keeps a download without one
    /// (`rules/` and the MD5 of its URL). Nothing outside `home` is read.
    static func file(path: String?, url: String?, home: URL) -> URL? {
        let candidate: URL
        if let path, !path.isEmpty {
            candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
        } else if let url {
            let hash = Insecure.MD5.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
            candidate = home.appendingPathComponent("rules").appendingPathComponent(hash)
        } else {
            return nil
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let root = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(root + "/"), FileManager.default.isReadableFile(atPath: resolved.path) else { return nil }
        return resolved
    }

    /// A rule-set file's entries: `payload:` in YAML, or one per line in text, without comments.
    static func entries(in text: String, format: String) -> [String] {
        if format == "yaml", case .sequence(let payload)? = (try? Yams.compose(yaml: text))?.mapping?[Node("payload")] {
            return payload.compactMap(\.string)
        }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }
    }

    // MARK: Geodata

    /// The core's GeoSite data, or Veer's own download.
    static func geosite(home: URL, fallback: GeoDataStore?) async -> (GeoSiteDatabase?, String?) {
        for name in ["GeoSite.dat", "geosite.dat"] {
            if let data = try? Data(contentsOf: home.appendingPathComponent(name), options: .mappedIfSafe),
               let database = try? GeoSiteDatabase(data: data) {
                return (database, name)
            }
        }
        if let database = try? await fallback?.geosite() { return (database, GeoDataFile.geosite.rawValue) }
        return (nil, nil)
    }

    /// GEOIP codes by address from the data the core reads: its MaxMind database, or with
    /// `geodata-mode` its GeoIP.dat; then Veer's own download.
    static func countries(home: URL, geodataMode: Bool, fallback: GeoDataStore?) async -> ((@Sendable (IPAddr) -> Set<String>)?, String?) {
        func maxMind() -> ((@Sendable (IPAddr) -> Set<String>), String)? {
            for name in ["geoip.metadb", "Country.mmdb", "country.mmdb"] {
                guard let data = try? Data(contentsOf: home.appendingPathComponent(name)), let database = try? MaxMindDatabase(data: data) else { continue }
                return ({ address in Self.codes(of: address, in: database) }, name)
            }
            return nil
        }
        func dat() -> ((@Sendable (IPAddr) -> Set<String>), String)? {
            for name in ["GeoIP.dat", "geoip.dat"] {
                guard let data = try? Data(contentsOf: home.appendingPathComponent(name), options: .mappedIfSafe),
                      let database = try? GeoIPDatabase(data: data) else { continue }
                return ({ address in Set(database.names(for: address).map { $0.uppercased() }) }, name)
            }
            return nil
        }
        if let found = geodataMode ? dat() ?? maxMind() : maxMind() ?? dat() { return found }
        if let database = try? await fallback?.geoip() {
            return ({ address in Set(database.names(for: address).map { $0.uppercased() }) }, GeoDataFile.geoip.rawValue)
        }
        return (nil, nil)
    }

    /// The codes a MaxMind record gives: one country, or MetaCubeX's list of codes.
    static func codes(of address: IPAddr, in database: MaxMindDatabase) -> Set<String> {
        guard let (value, _) = try? database.lookup(address), let code = value["country"]?["iso_code"] ?? value["country"] else { return [] }
        switch code {
        case .string(let text): return [text.uppercased()]
        case .array(let items): return Set(items.compactMap(\.string).map { $0.uppercased() })
        default: return []
        }
    }
}
