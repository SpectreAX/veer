import Foundation
import Testing
@testable import VeerCore

/// Links whose fields used to be dropped or mistyped, so the node loaded but could not connect.
/// Placeholder credentials, .invalid hosts and TEST-NET addresses only.
enum FixLinks {
    static let vmessUpgradeJSON = #"{"v":"2","ps":"VM Upgrade","add":"203.0.113.10","port":443,"id":"11111111-1111-1111-1111-111111111111","aid":0,"#
        + #""net":"httpupgrade","host":"cdn.example.invalid","path":"/up?ed=2048&eh=X-Early","tls":true,"allowInsecure":"1","fp":"chrome","sni":""}"#
    static let vmessUpgrade = vmess(vmessUpgradeJSON)
    static let vmessXTLS = vmess(#"{"ps":"VM XTLS","add":"vm.example.invalid","port":"443","id":"11111111-1111-1111-1111-111111111111","#
        + #""net":"tcp","tls":"xtls"}"#)
    static let vmessPlain = vmess(#"{"ps":"VM Plain","add":"vm.example.invalid","port":"80","id":"11111111-1111-1111-1111-111111111111","#
        + #""net":"ws","host":"cdn.example.invalid","tls":""}"#)
    static func vmess(_ json: String) -> String { "vmess://" + Data(json.utf8).base64EncodedString() }
    static let vlessUpgrade = "vless://22222222-2222-2222-2222-222222222222@vl.example.invalid:443?encryption=none&security=tls&type=httpupgrade&host=cdn.example.invalid&path=%2Fup%3Fed%3D2048&insecure=1#VL%20Upgrade"
    static let vlessSplit = "vless://22222222-2222-2222-2222-222222222222@vl.example.invalid:443?security=tls&peer=peer.example.invalid&type=splithttp&path=/a+b&mode=auto#VL%20Split"
    static let vmessAEAD = "vmess://11111111-1111-1111-1111-111111111111@vm.example.invalid:443?security=tls&type=ws&host=cdn.example.invalid&path=%2Fws&allowInsecure=true#AEAD"
    static let trojanWS = "trojan://p%ss@tj.example.invalid:443?peer=tj2.example.invalid&insecure=1&type=ws&host=cdn.example.invalid&ed=2048#Trojan%20WS"
    static let trojanTCP = "trojan://pw@tj.example.invalid:443?type=tcp&sni=tj.example.invalid#Trojan%20TCP"
    static let trojanOriginal = "trojan://pw@tj.example.invalid:443?type=original#Trojan%20Go"
    static let hy2Hop = "hy2://auth@hy.example.invalid:443?mport=20000-30000&obfs=none&obfs-password=&allowInsecure=1&upmbps=50&downmbps=200#Hy2%20mport"
    static let hy2NoObfsPassword = "hysteria2://auth@hy.example.invalid:443?obfs=salamander#Hy2%20half%20obfs"
    static let hysteria = "hysteria://hy1.example.invalid:443?peer=s.example.invalid&auth=a&protocol=udp&allowInsecure=1#Hy1"
    static let hysteriaRates = "hysteria://hy1.example.invalid:443?upmbps=30&down=80%20Mbps#Hy1%20rates"
    static let tuic = "tuic://33333333-3333-3333-3333-333333333333:pw@tu.example.invalid:443?allow_insecure=1&disable_sni=true&alpn=h3#TUIC%20insecure"
    static let anytls = "anytls://pw@at.example.invalid:443?insecure=1&fp=chrome&alpn=h2,http/1.1#AnyTLS"
    static let anytlsPinned = "anytls://pw@at.example.invalid:443?sni=at.example.invalid&hpkp=abc123#AnyTLS%20pinned"
    static let ssV2rayTLSHost = "ss://" + Data("aes-128-gcm:pw".utf8).base64EncodedString()
        + "@ss.example.invalid:443?plugin=v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3Dtls.example.invalid%3Bpath%3D%2Fws#V2%20no%20tls"
    static let ssV2rayTLS = "ss://" + Data("aes-128-gcm:pw".utf8).base64EncodedString()
        + "@ss.example.invalid:443?plugin=v2ray-plugin%3Btls%3Bhost%3Dcdn.example.invalid%3Bskip-cert-verify%3Dtrue#V2%20tls"

    static var all: [String] {
        [vmessUpgrade, vmessXTLS, vmessPlain, vlessUpgrade, vlessSplit, vmessAEAD, trojanWS, trojanTCP, trojanOriginal, hy2Hop,
         hy2NoObfsPassword, hysteria, hysteriaRates, tuic, anytls, anytlsPinned, ssV2rayTLSHost, ssV2rayTLS]
    }
}

struct ShareLinkFixTests {
    func proxy(_ link: String) throws -> YAMLValue {
        .map(try #require(ShareLinkParser.parse(link).proxies.first, "\(link)"))
    }

    @Test func queryKeepsPlusAndUserInfoKeepsAStrayPercent() throws {
        let link = try #require(ShareLinkParser.split("trojan://p%ss@h.example.invalid:1?path=/a+b&q=%2B1#n"))
        #expect(link.user == "p%ss" && link.query["path"] == "/a+b" && link.query["q"] == "+1")
        #expect(try proxy(FixLinks.trojanWS)["password"] == .string("p%ss"))
    }

    @Test func vmessJSONHTTPUpgradeIsWSWithUpgrade() throws {
        let vmess = try proxy(FixLinks.vmessUpgrade)
        #expect(vmess["network"] == .string("ws"))
        #expect(vmess["ws-opts"]?["v2ray-http-upgrade"] == .bool(true))
        #expect(vmess["ws-opts"]?["v2ray-http-upgrade-fast-open"] == .bool(true))
        #expect(vmess["ws-opts"]?["path"] == .string("/up"))
        #expect(vmess["ws-opts"]?["max-early-data"] == nil)
        // A JSON true is TLS; no sni falls back to the Host; allowInsecure and fp come through.
        #expect(vmess["tls"] == .bool(true) && vmess["servername"] == .string("cdn.example.invalid"))
        #expect(vmess["skip-cert-verify"] == .bool(true) && vmess["client-fingerprint"] == .string("chrome"))
    }

    @Test func vmessJSONTLSWords() throws {
        #expect(try proxy(FixLinks.vmessXTLS)["tls"] == .bool(true))
        let plain = try proxy(FixLinks.vmessPlain)
        #expect(plain["tls"] == .bool(false) && plain["servername"] == nil && plain["skip-cert-verify"] == .bool(false))
        #expect(try proxy(Links.vmess)["skip-cert-verify"] == .bool(false))
    }

    @Test func vShareHTTPUpgradeSNIAndXHTTP() throws {
        let vless = try proxy(FixLinks.vlessUpgrade)
        #expect(vless["network"] == .string("ws") && vless["ws-opts"]?["v2ray-http-upgrade"] == .bool(true))
        #expect(vless["ws-opts"]?["v2ray-http-upgrade-fast-open"] == .bool(true) && vless["ws-opts"]?["path"] == .string("/up"))
        #expect(vless["servername"] == .string("cdn.example.invalid") && vless["skip-cert-verify"] == .bool(true))
        let split = try proxy(FixLinks.vlessSplit)
        #expect(split["network"] == .string("xhttp") && split["servername"] == .string("peer.example.invalid"))
        #expect(split["xhttp-opts"]?["path"] == .string("/a+b") && split["skip-cert-verify"] == nil)
        let aead = try proxy(FixLinks.vmessAEAD)
        #expect(aead["skip-cert-verify"] == .bool(true) && aead["ws-opts"]?["v2ray-http-upgrade"] == nil)
        // Plain ws keeps its early data as before.
        #expect(try proxy(Links.vmess)["ws-opts"]?["v2ray-http-upgrade"] == nil)
    }

    @Test func trojanPeerInsecureAndNetwork() throws {
        let ws = try proxy(FixLinks.trojanWS)
        #expect(ws["sni"] == .string("tj2.example.invalid") && ws["skip-cert-verify"] == .bool(true))
        #expect(ws["network"] == .string("ws") && ws["ws-opts"]?["path"] == .string("/"))
        #expect(ws["ws-opts"]?["max-early-data"] == .int(2048) && ws["ws-opts"]?["headers"]?["Host"] == .string("cdn.example.invalid"))
        #expect(try proxy(FixLinks.trojanTCP)["network"] == nil)
        #expect(try proxy(FixLinks.trojanOriginal)["network"] == nil)
    }

    @Test func hysteria2PortsObfsAndRates() throws {
        let hop = try proxy(FixLinks.hy2Hop)
        #expect(hop["port"] == .int(443) && hop["ports"] == .string("20000-30000"))
        #expect(hop["obfs"] == nil && hop["obfs-password"] == nil && hop["skip-cert-verify"] == .bool(true))
        #expect(hop["up"] == .string("50") && hop["down"] == .string("200"))
        let half = try proxy(FixLinks.hy2NoObfsPassword)
        #expect(half["obfs"] == nil && half["obfs-password"] == nil)
        // A port list in the address wins over mport.
        #expect(try proxy(Links.hy2)["ports"] == .string("443,20000-30000"))
        #expect(try proxy(Links.hy2)["obfs-password"] == .string("ob"))
    }

    @Test func hysteriaV1NeverWritesAnEmptyRate() throws {
        let bare = try proxy(FixLinks.hysteria)
        #expect(bare["up"] == .string(ShareLinkParser.hysteriaDefaultBandwidth) && bare["down"] == .string(ShareLinkParser.hysteriaDefaultBandwidth))
        #expect(bare["sni"] == .string("s.example.invalid") && bare["skip-cert-verify"] == .bool(true))
        let rates = try proxy(FixLinks.hysteriaRates)
        #expect(rates["up"] == .string("30") && rates["down"] == .string("80 Mbps"))
    }

    @Test func tuicAndAnyTLS() throws {
        let tuic = try proxy(FixLinks.tuic)
        #expect(tuic["skip-cert-verify"] == .bool(true) && tuic["disable-sni"] == .bool(true))
        #expect(try proxy(Links.tuic)["skip-cert-verify"] == nil)
        let anytls = try proxy(FixLinks.anytls)
        #expect(anytls["sni"] == nil && anytls["fingerprint"] == nil && anytls["skip-cert-verify"] == .bool(true))
        #expect(anytls["client-fingerprint"] == .string("chrome") && anytls["alpn"] == .list([.string("h2"), .string("http/1.1")]))
        let pinned = try proxy(FixLinks.anytlsPinned)
        #expect(pinned["sni"] == .string("at.example.invalid") && pinned["fingerprint"] == .string("abc123") && pinned["skip-cert-verify"] == .bool(false))
    }

    @Test func v2rayPluginTLSIsTheExactFlag() throws {
        let hostOnly = try proxy(FixLinks.ssV2rayTLSHost)
        #expect(hostOnly["plugin-opts"]?["tls"] == .bool(false) && hostOnly["plugin-opts"]?["host"] == .string("tls.example.invalid"))
        #expect(hostOnly["plugin-opts"]?["skip-cert-verify"] == nil)
        let tls = try proxy(FixLinks.ssV2rayTLS)
        #expect(tls["plugin-opts"]?["tls"] == .bool(true) && tls["plugin-opts"]?["skip-cert-verify"] == .bool(true))
        // No mode is v2ray-plugin's default, websocket.
        #expect(tls["plugin-opts"]?["mode"] == .string("websocket"))
    }

    @Test func subscriptionsAskForMihomoYAML() {
        for word in ["Clash", "ClashMeta", "clash.meta", "mihomo"] { #expect(SubscriptionFetcher.userAgent.contains(word), "\(word)") }
    }
}

struct ImportFixTests {
    @Test func base64OfAFullConfigIsTheConfig() throws {
        #expect(SampleConfig.text.contains("://"))
        let result = try ConfigImporter.normalize(Data(SampleConfig.text.utf8).base64EncodedString())
        #expect(result.format == .mihomoYAML && result.text == SampleConfig.text)
        let list = "proxies:\n  - {name: a, type: ss, server: a.example.invalid, port: 1, cipher: aes-128-gcm, password: p}\n"
        #expect(try ConfigImporter.normalize(Data(list.utf8).base64EncodedString()).format == .proxyListYAML)
    }

    @Test func base64OfALinkThatReadsAsYAMLIsStillALink() throws {
        let link = "trojan://pw@tj.example.invalid:443?sni=tj.example.invalid#HK: 01"
        let result = try ConfigImporter.normalize(Data(link.utf8).base64EncodedString())
        #expect(result.format == .base64Links && result.nodeCount == 1)
    }

    @Test func yesAndNoUnderBooleanKeysBecomeBooleans() throws {
        let list = """
        - {name: a, type: trojan, server: a.example.invalid, port: 443, password: x, udp: yes, tfo: 'on', skip-cert-verify: No}
        - {name: b, type: ss, server: b.example.invalid, port: 1, cipher: aes-128-gcm, password: yes, plugin: obfs, plugin-opts: {mode: http, tls: off}}
        """
        let result = try ConfigImporter.normalize(list)
        #expect(result.text.contains("udp: true") && result.text.contains("tfo: true") && result.text.contains("skip-cert-verify: false"))
        #expect(result.text.contains("tls: false"))
        // Other keys keep the word: a password of "yes" stays a string.
        #expect(result.text.contains("password: 'yes'"))
    }
}

/// Runs only when VEER_MIHOMO_BIN points at a Mihomo binary.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VEER_MIHOMO_BIN"] != nil))
struct ShareLinkCoreTests {
    @Test(arguments: FixLinks.all) func eachConvertedLinkPassesMihomo(link: String) async throws {
        let result = try ConfigImporter.normalize(link)
        #expect(result.nodeCount == 1)
        let check = await MihomoValidator().validate(result.text)
        #expect(check.status == .passed, "\(link): \(check.message) \(check.detail ?? "")")
    }

    @Test func allTogetherPassMihomo() async throws {
        let result = try ConfigImporter.normalize(FixLinks.all.joined(separator: "\n"))
        #expect(result.nodeCount == FixLinks.all.count && result.skipped.isEmpty)
        let check = await MihomoValidator().validate(result.text)
        #expect(check.status == .passed, "\(check.message) \(check.detail ?? "")")
    }

    @Test func aNodeListWithYesPassesMihomo() async throws {
        let list = "- {name: a, type: trojan, server: a.example.invalid, port: 443, password: x, udp: yes, tfo: yes}"
        let check = await MihomoValidator().validate(try ConfigImporter.normalize(list).text)
        #expect(check.status == .passed, "\(check.message) \(check.detail ?? "")")
    }
}
