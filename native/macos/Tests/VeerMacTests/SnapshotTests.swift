import AppKit
import SwiftUI
import Testing
import VeerEditor
@testable import VeerMac

/// Opt-in visual check: writes PNGs of the prototype-aligned states for manual review.
/// Run with VEER_TEST_PORT (a local editor service) and VEER_SNAPSHOT_DIR set.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_SNAPSHOT_DIR"] != nil && ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) @MainActor
func writeEditorSnapshots() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VEER_SNAPSHOT_DIR"]))
    let raw = try #require(ProcessInfo.processInfo.environment["VEER_TEST_PORT"])
    let port = try #require(Int(raw))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let yaml = "proxy-groups:\n  - name: 🇯🇵 日本 自动\n    type: select\n    proxies: [DIRECT]\n  - name: 🇺🇸 美国 流媒体\n    type: select\n    proxies: [DIRECT]\n  - name: Auto-Fallback-Global-Selector-Without-Region-Label\n    type: select\n    proxies: [DIRECT]\nrules:\n  - DOMAIN-SUFFIX,Netflix.com,DIRECT\n  - GEOSITE,cn,DIRECT\n  - MATCH,DIRECT\n"

    func render(_ model: EditorModel, _ name: String, dark: Bool = false, width: CGFloat = 1440, height: CGFloat = 900) throws {
        let host = NSHostingView(rootView: EditorView(model: model))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
    func waitIdle(_ model: EditorModel) async throws {
        let deadline = Date().addingTimeInterval(10)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    let start = EditorModel(client: try EditorClient(port: port))
    try await start.acceptImport(yaml, name: "veer-demo.yaml", revision: start.session.revision)
    try render(start, "01-start-region-check")

    let model = EditorModel(client: try EditorClient(port: port))
    try await model.acceptImport(yaml, name: "veer-demo.yaml", revision: model.session.revision)
    model.prompt = "Netflix 走日本，ChatGPT 走美国"
    model.generate()
    try await waitIdle(model)
    var clarify = ConversationTurn(prompt: "节点太卡了", mode: "ai", fileName: "veer-demo.yaml", groups: model.session.draft.groups)
    clarify.state = .clarify
    clarify.message = "我无法测速，也不会判断哪个出口更快。你想把哪项服务固定到哪个地区？"
    clarify.steps = ["已匿名化上下文。", "AI 请求澄清；没有生成候选。"]
    model.conversation.append(clarify)
    try render(model, "02-pending-review-light")
    try render(model, "03-pending-review-dark", dark: true)

    model.confirm()
    model.review.show(.rules)
    model.refreshRuleList()
    try await Task.sleep(for: .milliseconds(400))
    try render(model, "04-rules-tab-unexported")
    model.testDomain = "www.netflix.com"
    model.openDomainTest("www.netflix.com")
    try await Task.sleep(for: .milliseconds(400))
    try render(model, "06-test-tab")

    let failed = try JSONDecoder().decode(Validation.self, from: Data(#"{"status":"failed","message":"Mihomo 校验失败：rules[0] 引用的出口在占位配置中不存在。"}"#.utf8))
    if let index = model.conversation.firstIndex(where: { $0.preview != nil }), let preview = model.conversation[index].preview {
        var blocked = model.conversation[index]
        let json = try JSONEncoder().encode(preview)
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object["validation"] = ["status": failed.status, "message": failed.message]
        blocked = ConversationTurn(prompt: "YouTube 走香港", mode: "local", fileName: "veer-demo.yaml", groups: [])
        blocked.preview = try JSONDecoder().decode(Preview.self, from: JSONSerialization.data(withJSONObject: object))
        blocked.diffLines = model.conversation[index].diffLines
        blocked.state = .blocked
        blocked.message = "已生成修改，但校验没有通过，此候选不能确认。"
        model.conversation.append(blocked)
        model.openReview(blocked.id)
        try render(model, "05-blocked-compact", width: 1080, height: 760)
    }
}
