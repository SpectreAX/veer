// Simulator smoke test for MihomoCore.xcframework, run by test-mihomo-ios-sim.sh through
// `xcrun simctl spawn`. Usage: harness <work-dir>. Uses only 127.0.0.1; no system proxy.
import Foundation
import MihomoCore

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let home = dir.appendingPathComponent("home")
let configURL = home.appendingPathComponent("config.yaml")
let secret = "veer-harness-secret"
let controller = "127.0.0.1:19091"

let goodYAML = """
mixed-port: 17891
allow-lan: false
external-controller: \(controller)
secret: \(secret)
mode: rule
log-level: info
proxies: []
rules:
  - MATCH,DIRECT

"""
let badSyntaxYAML = "mixed-port: [17891\nrules: {"
let badProxyYAML = """
proxies:
  - {name: broken, type: no-such-type, server: 127.0.0.1, port: 1}
rules:
  - MATCH,broken

"""

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "PASS" : "FAIL") \(what)")
    if !ok { failures += 1 }
}

func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
    guard let p else { return nil }
    defer { VeerCoreFree(p) }
    return String(cString: p)
}

func start() -> String? { take(VeerCoreStart(home.path, configURL.path)) }
func validate(_ yaml: String) -> String? { take(VeerCoreValidate(yaml)) }

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]
    c.timeoutIntervalForRequest = 3
    return URLSession(configuration: c)
}()

/// Returns (status, body) or (nil, error text).
func get(_ url: String, bearer: String?) -> (Int?, String) {
    var req = URLRequest(url: URL(string: url)!)
    if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    let done = DispatchSemaphore(value: 0)
    var result: (Int?, String) = (nil, "no response")
    session.dataTask(with: req) { data, resp, err in
        if let err { result = (nil, err.localizedDescription) } else {
            result = ((resp as? HTTPURLResponse)?.statusCode, String(decoding: data ?? Data(), as: UTF8.self))
        }
        done.signal()
    }.resume()
    done.wait()
    return result
}

try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
try goodYAML.write(to: configURL, atomically: true, encoding: .utf8)

let version = take(VeerCoreVersion()) ?? ""
print("VeerCoreVersion: \(version)")
check(version == "v1.19.29", "version is v1.19.29")

let vGood = validate(goodYAML)
check(vGood == nil, "validate good YAML -> \(vGood ?? "nil")")
let vSyntax = validate(badSyntaxYAML)
check(vSyntax != nil, "validate bad-syntax YAML -> \(vSyntax ?? "nil")")
let vProxy = validate(badProxyYAML)
check(vProxy != nil, "validate bad-proxy YAML -> \(vProxy ?? "nil")")

for round in 1...2 {
    let t0 = Date()
    let err = start()
    check(err == nil, "round \(round): start -> \(err ?? "nil") in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")

    let (s1, b1) = get("http://\(controller)/version", bearer: secret)
    check(s1 == 200 && b1.contains("v1.19.29"), "round \(round): GET /version with secret -> \(s1.map(String.init) ?? "nil") \(b1.trimmingCharacters(in: .whitespacesAndNewlines))")
    let (s2, b2) = get("http://\(controller)/version", bearer: nil)
    check(s2 == 401, "round \(round): GET /version without secret -> \(s2.map(String.init) ?? "nil") \(b2.trimmingCharacters(in: .whitespacesAndNewlines))")
    let (s3, b3) = get("http://\(controller)/configs", bearer: secret)
    check(s3 == 200 && b3.contains("\"mixed-port\":17891"), "round \(round): GET /configs reports mixed-port 17891")

    let again = start()
    check(again != nil, "round \(round): second start while running is refused -> \(again ?? "nil")")

    if round == 1 {
        // Let the host side hit the controller and the mixed port (simulator shares the host network).
        let ready = dir.appendingPathComponent("ready")
        let proceed = dir.appendingPathComponent("continue")
        FileManager.default.createFile(atPath: ready.path, contents: nil)
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: proceed.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        check(FileManager.default.fileExists(atPath: proceed.path), "round 1: host-side checks finished")
    }

    let t1 = Date()
    VeerCoreStop()
    print("round \(round): stop took \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")
    let (s4, b4) = get("http://\(controller)/version", bearer: secret)
    check(s4 == nil, "round \(round): controller closed after stop -> \(s4.map(String.init) ?? b4)")
    let (s5, b5) = get("http://127.0.0.1:17891/", bearer: nil)
    check(s5 == nil, "round \(round): mixed port closed after stop -> \(s5.map(String.init) ?? b5)")
}
VeerCoreStop() // no-op when stopped

let files = (FileManager.default.enumerator(atPath: home.path)?.allObjects as? [String] ?? []).sorted()
print("home dir contents: \(files)")
let geo = files.filter { $0.lowercased().contains("geo") || $0.lowercased().hasSuffix(".mmdb") || $0.lowercased().hasSuffix(".dat") }
check(geo.isEmpty, "no geodata files downloaded -> \(geo)")

print(failures == 0 ? "HARNESS RESULT: ALL PASS" : "HARNESS RESULT: \(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
