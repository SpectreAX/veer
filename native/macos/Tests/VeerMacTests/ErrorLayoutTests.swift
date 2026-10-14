import AppKit
import SwiftUI
import Testing
import VeerEditor
@testable import VeerMac

@Test(.enabled(if: ProcessInfo.processInfo.environment["VEER_TEST_PORT"] != nil)) @MainActor
func failureLayoutKeepsWindowSize() async throws {
    let port = try #require(Int(ProcessInfo.processInfo.environment["VEER_TEST_PORT"] ?? ""))
    let model = EditorModel(client: try EditorClient(port: port))
    try await model.acceptImport("rules:\n  - MATCH,DIRECT\n", name: "error-layout.yaml", revision: model.session.revision)
    let message = "“巴哈姆特走台湾和香港”无法确定唯一出口：台湾与香港节点各有多条，且未说明是分流还是同时指定。请指定一个具体出口（例如“出口18（台湾）”或“出口14（香港）”），或说明分流规则。"
    model.issue = message
    var turn = ConversationTurn(prompt: "巴哈姆特走台湾和香港", mode: "ai", fileName: "error-layout.yaml", groups: [])
    turn.state = .failed; turn.message = message
    model.conversation = [turn]
    let host = NSHostingView(rootView: EditorView(model: model))
    host.frame = NSRect(x: 0, y: 0, width: 1120, height: 860)
    host.layoutSubtreeIfNeeded()
    let fitting = host.fittingSize
    print("Error layout fitting size: \(fitting)")
    #expect(fitting.height <= 860)
}
