import AppKit
import SwiftUI
import VeerCore
import VeerProxy

/// `VEER_SNAPSHOT_DIR=… Veer`: renders each screen and state, light and dark, from sample data
/// in a throwaway directory. It never starts a core or touches the system proxy.
enum SnapshotRunner {
    static func run(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let appearances = (ProcessInfo.processInfo.environment["VEER_SNAPSHOT_APPEARANCE"] ?? "light,dark").split(separator: ",").map(String.init)
        // `VEER_SNAPSHOT_SCENES=05,25`: only the scenes whose names start with these.
        let only = ProcessInfo.processInfo.environment["VEER_SNAPSHOT_SCENES"]?.split(separator: ",").map(String.init)
        Task { @MainActor in
            for appearance in appearances {
                let name = appearance == "dark" ? NSAppearance.Name.darkAqua : .aqua
                for scene in scenes() where only?.contains(where: scene.name.hasPrefix) ?? true {
                    let store = scene.store()
                    let agent = AgentStore(proxy: store, keyStore: FileKeyStore(url: store.paths.secrets),
                                           defaults: UserDefaults(suiteName: "veer-snapshot-agent-\(UUID().uuidString)")!, persist: false)
                    scene.agent?(agent)
                    // The app's window never gets smaller than this; content sized views would shrink it.
                    // Scenes that want a setting say so; without this they draw the user's own.
                    let content = scene.view.defaultAppStorage(UserDefaults(suiteName: "veer-snapshot-\(UUID().uuidString)")!)
                    let view = scene.fullScreen
                        ? AnyView(content.environment(store).environment(agent).tint(.veerAccent))
                        : scene.resizable
                        ? AnyView(content.environment(store).environment(agent).tint(.veerAccent)
                            .frame(minWidth: scene.size.width, minHeight: scene.size.height))
                        : AnyView(content.environment(store).environment(agent).tint(.veerAccent).frame(width: scene.size.width, height: scene.size.height))
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: scene.size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                    // As the app's window: a fixed one counts as zoomed, and the Agent panel does not widen it.
                    if scene.resizable { window.styleMask.insert(.resizable) }
                    window.appearance = NSAppearance(named: name)
                    let hosting = NSHostingController(rootView: view)
                    if scene.standardWindow {
                        window.styleMask.insert(.miniaturizable)
                        window.styleMask.insert(.resizable)
                        // The view's title and toolbar on the window, as a `Window` scene puts them.
                        hosting.sceneBridgingOptions = [.title, .toolbars]
                    } else {
                        // As `.windowStyle(.hiddenTitleBar)` leaves the app's window.
                        window.titleVisibility = .hidden
                        window.titlebarAppearsTransparent = true
                    }
                    window.contentViewController = hosting
                    window.setContentSize(scene.size)
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    let path = directory.appendingPathComponent("\(scene.name)-\(appearance).png")
                    if scene.fullScreen {
                        await captureFullScreen(window, to: path)
                    } else {
                        try? await Task.sleep(for: .milliseconds(700))
                        capture(window, to: path)
                    }
                    window.childWindows?.forEach { $0.orderOut(nil) }
                    window.orderOut(nil)
                }
                // Laid out and shown, never run: nothing here can register the helper.
                for (consent, suffix) in [(HelperState.TUNConsent.install, "install"), (.approve, "approve")] {
                    let alert = HelperPrompt.alert(for: consent)
                    alert.window.appearance = NSAppearance(named: name)
                    alert.layout()
                    alert.window.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    try? await Task.sleep(for: .milliseconds(900))
                    capture(alert.window, to: directory.appendingPathComponent("33-tun-\(suffix)-\(appearance).png"))
                    alert.window.orderOut(nil)
                }
            }
            NSApp.terminate(nil)
        }
    }

    private static let longNamedGroups: [ProxyStore.Group] = {
        typealias Member = ProxyStore.Group.Member
        let nodes = [Member(name: "🇸🇬 新加坡 03-0.1倍 | 电信联通推荐", delay: 88, isGroup: false),
                     Member(name: "🇺🇸 美国 02-0.1倍 | 电信移动推荐", delay: 154, isGroup: false),
                     Member(name: "🇯🇵 日本 01-1倍 | 三网优化", delay: 99, isGroup: false),
                     Member(name: "🇯🇵 日本东京特别专线 IPLC 01 | 0.5x 高速稳定线路备用节点名字很长", delay: 120, isGroup: false)]
        return [.init(name: "🚀 节点选择", type: "Selector", now: nodes[0].name, members: nodes),
                .init(name: "♻️ 自动选择", type: "URLTest", now: nodes[0].name, members: nodes),
                .init(name: "🇸🇬 狮城节点", type: "Selector", now: nodes[3].name, members: nodes),
                .init(name: "这是一个名字特别特别长的专用策略组用来检查标题行", type: "Selector", now: nodes[1].name, members: nodes),
                .init(name: "🛑 广告拦截", type: "Selector", now: "REJECT",
                      members: [Member(name: "REJECT", delay: nil, isGroup: false), Member(name: "DIRECT", delay: 3, isGroup: false)])]
    }()

    private static func attachmentThread(_ agent: AgentStore) {
        agent.settings.provider = .ollama
        sampleThread(agent, status: .pending)
        agent.current?.turns[0].attachments = [AttachmentInfo(name: "筛选结果.yaml", kind: .text, redacted: true),
                                               AttachmentInfo(name: "很长很长很长很长的连接日志导出文件名称.log", kind: .text, truncated: true)]
        agent.attachmentProblem = String(localized: "不支持“\("archive.zip")”。可以发送图片、文本、PDF、RTF 和 Word 文档。")
        agent.pendingAttachments = [ChatAttachment.file(named: "规则.txt", text: "mini4k.net"),
                                    ChatAttachment(info: AttachmentInfo(name: "屏幕截图 2026-11-01.png", kind: .image), image: sampleImage),
                                    ChatAttachment(info: AttachmentInfo(name: "很长很长很长很长的连接日志导出文件名称.log", kind: .text, truncated: true, redacted: true),
                                                   text: "")]
    }

    private static var sampleImage: AIImage? {
        let image = NSImage(systemSymbolName: "map", accessibilityDescription: nil)
        return image?.tiffRepresentation.map { AIImage(data: $0, mediaType: "image/tiff") }
    }

    private static func mapDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "veer-snapshot-\(UUID().uuidString)")!
        defaults.set(true, forKey: "proxiesShowMap")
        return defaults
    }

    struct Scene {
        let name: String
        var size = CGSize(width: 1080, height: 720)
        let store: () -> ProxyStore
        let view: AnyView
        /// Fills the Agent page's state, for its scenes.
        var agent: ((AgentStore) -> Void)? = nil
        /// Takes the window into full screen, in its own Space, for the capture.
        var fullScreen = false
        /// Resizable with a minimum size, as the app's own window is.
        var resizable = false
        /// A standard window with its title and toolbar, as the Agent's window is, rather than the
        /// main window's hidden title bar.
        var standardWindow = false
    }

    // swiftlint:disable:next function_body_length
    static func scenes() -> [Scene] { // A flat list that grows with every screen.
        [
            Scene(name: "01-onboarding-add", store: { sample(profiles: false) }, view: AnyView(MainView())),
            Scene(name: "02-onboarding-routing", store: {
                let store = sample()
                store.onboarding = .routing
                return store
            }, view: AnyView(MainView())),
            Scene(name: "03-onboarding-start", store: {
                let store = running()
                store.onboarding = .start
                return store
            }, view: AnyView(MainView())),
            Scene(name: "04-overview-running", store: { running() }, view: AnyView(MainView())),
            Scene(name: "05-proxies", store: { running(page: .proxies) }, view: AnyView(MainView())),
            Scene(name: "06-profiles", size: CGSize(width: 520, height: 520), store: { sample() }, view: AnyView(ProfilesSheet())),
            Scene(name: "06a-profiles-duplicates", size: CGSize(width: 520, height: 520), store: { profilesWithDuplicates() },
                  view: AnyView(ProfilesSheet())),
            Scene(name: "06b-profiles-restore", size: CGSize(width: 520, height: 520), store: { sample() },
                  view: AnyView(ProfilesSheet(removedCopies: removedProfileSamples()))),
            Scene(name: "06c-profiles-restore-failed", size: CGSize(width: 520, height: 520), store: { sample() },
                  view: AnyView(ProfilesSheet(removedCopies: removedProfileSamples(count: 1),
                                              mergeProblem: String(localized: "有 \(1) 份副本未能恢复。你可以重试。")))),
            Scene(name: "06d-profiles-duplicates-protected", size: CGSize(width: 520, height: 520), store: { profilesWithDuplicates(protected: true) },
                  view: AnyView(ProfilesSheet())),
            Scene(name: "06e-profiles-restored", size: CGSize(width: 520, height: 520), store: { profilesWithDuplicates() },
                  view: AnyView(ProfilesSheet(restoreResult: String(localized: "已恢复 \(2) 份副本。")))),
            Scene(name: "06b-tools", store: { running(page: .tools) }, view: AnyView(MainView())),
            Scene(name: "04d-overview-detecting", store: {
                let store = running()
                store.exit = nil
                return store
            }, view: AnyView(MainView())),
            // Nothing reaches the core, while the exit still looks right.
            Scene(name: "04g-overview-no-proxy", store: {
                let store = running()
                store.systemProxyOn = false
                return store
            }, view: AnyView(MainView())),
            Scene(name: "04h-overview-lan", store: { running(lan: true) }, view: AnyView(MainView())),
            // Stopped with the proxy remembered, and with LAN on: neither is in effect yet.
            Scene(name: "04i-overview-stopped", store: {
                let store = running(lan: true)
                store.phase = .stopped
                store.systemProxyOn = false
                store.exit = nil
                store.systemProxyRemembered = true
                return store
            }, view: AnyView(MainView())),
            // The address's narrowest place, beside the Agent panel in the smallest window.
            Scene(name: "24e-panel-narrow-lan", size: CGSize(width: 860, height: 640), store: { running(panel: true, lan: true) }, view: AnyView(MainView())),
            Scene(name: "04f-overview-starting", store: {
                let store = running()
                store.phase = .starting
                return store
            }, view: AnyView(MainView())),
            // Long enough to wrap: this page has no scroll of its own up there.
            Scene(name: "05c-proxies-notice-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .proxies)
                store.notice = String(localized: "TUN 未能启动，已改用系统代理。\(String(localized: "需要在系统设置的“登录项”中允许 Veer 的后台服务。"))")
                return store
            }, view: AnyView(MainView())),
            Scene(name: "05b-proxies-smallest", size: CGSize(width: 860, height: 560), store: { running(page: .proxies) }, view: AnyView(MainView())),
            Scene(name: "04e-overview-no-exit", store: {
                let store = running()
                store.exit = .unknown
                return store
            }, view: AnyView(MainView())),
            // A failed start is explained wherever it was started from.
            Scene(name: "07b-failed-proxies", store: { failed(page: .proxies) }, view: AnyView(MainView())),
            Scene(name: "07c-failed-connections", store: { failed(page: .connections) }, view: AnyView(MainView())),
            Scene(name: "07d-failed-dns", store: { failed(page: .dns) }, view: AnyView(MainView())),
            Scene(name: "07e-failed-logs", store: { failed(page: .logs) }, view: AnyView(MainView())),
            Scene(name: "07f-failed-requests", store: { failed(page: .requests) }, view: AnyView(MainView())),
            // Onboarding has no scroll, so this has to fit the smallest window.
            Scene(name: "03c-onboarding-failed-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = failed(page: .overview)
                store.onboarding = .start
                return store
            }, view: AnyView(MainView())),
            Scene(name: "03b-onboarding-failed", store: {
                let store = failed(page: .overview)
                store.onboarding = .start
                return store
            }, view: AnyView(MainView())),
            Scene(name: "07-failed", store: {
                let store = sample()
                store.phase = .failed(String(localized: "端口 \(String(7890)) 已被其他程序占用。退出占用它的代理软件，或在设置中换一个端口。"), log: [
                    "time=\"2026-10-29T10:00:00+08:00\" level=info msg=\"Start initial configuration in progress\"",
                    "time=\"2026-10-29T10:00:00+08:00\" level=error msg=\"Start Mixed(http+socks) server error: listen tcp 127.0.0.1:7890: bind: address already in use\"",
                ])
                return store
            }, view: AnyView(MainView())),
            // A subscription that came back with a group and no nodes: stopped before the core starts.
            Scene(name: "07g-failed-empty-group", size: CGSize(width: 860, height: 560), store: {
                let store = sample()
                store.phase = .failed(String(localized: "策略组“\("♻️ 自动选择")”没有节点或 Provider，无法启动。请更新订阅或换用有效配置；本地配置可在“编辑成员”中修复。"), log: [])
                return store
            }, view: AnyView(MainView())),
            // Another program held the port picked for the core's controller: stopped at once, not after a minute.
            Scene(name: "07h-failed-controller-port", store: { controllerPortTaken() }, view: AnyView(MainView())),
            Scene(name: "07i-failed-controller-port-smallest", size: CGSize(width: 860, height: 560), store: { controllerPortTaken() },
                  view: AnyView(MainView())),
            Scene(name: "08-proxies-stopped", store: {
                let store = sample()
                store.page = .proxies
                return store
            }, view: AnyView(MainView())),
            // The core stopped on the pages that need it. Without a profile the app shows onboarding instead.
            Scene(name: "08f-empty-stopped-connections", store: { stopped(page: .connections) }, view: AnyView(MainView())),
            Scene(name: "08g-empty-stopped-logs-narrow", size: CGSize(width: 860, height: 560), store: { stopped(page: .logs) }, view: AnyView(MainView())),
            Scene(name: "08h-stopped-start-proxy", store: {
                let store = stopped(page: .connections)
                store.systemProxyRemembered = true
                return store
            }, view: AnyView(MainView())),
            Scene(name: "08i-stopped-start-tun", size: CGSize(width: 860, height: 560), store: {
                let store = stopped(page: .logs)
                store.agentPanel = true
                store.settings.tun = true
                return store
            }, view: AnyView(MainView())),
            Scene(name: "08j-retry-tun-and-proxy", size: CGSize(width: 1320, height: 820), store: {
                let store = failed(page: .requests)
                store.settings.tun = true
                store.systemProxyRemembered = true
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09-agent-setup", store: { running(page: .agent) }, view: AnyView(MainView())),
            Scene(name: "09b-agent-welcome", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
            }),
            Scene(name: "09c-agent-proposal", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            // Files waiting in the composer, and files already sent.
            Scene(name: "09p-agent-attachments", store: { running(page: .agent) }, view: AnyView(MainView()), agent: attachmentThread),
            Scene(name: "09q-panel-attachments", size: CGSize(width: 860, height: 640), store: { running(page: .overview, panel: true) },
                  view: AnyView(MainView()), agent: attachmentThread),
            Scene(name: "09s-attachments-smallest", size: CGSize(width: 860, height: 560), store: { running(page: .overview, panel: true) },
                  view: AnyView(MainView()), agent: { agent in
                attachmentThread(agent)
                agent.pendingAttachments.append(.file(named: "additional-rules.txt", text: "example.com"))
            }),
            Scene(name: "09t-attachments-loading", size: CGSize(width: 860, height: 560), store: { running(page: .agent) },
                  view: AnyView(MainView()), agent: { agent in
                attachmentThread(agent)
                agent.loadingAttachments = 1
            }),
            Scene(name: "09u-attachments-unavailable", size: CGSize(width: 860, height: 560), store: { running(page: .agent) },
                  view: AnyView(MainView()), agent: { agent in
                attachmentThread(agent)
                agent.pendingAttachments = []
                agent.attachmentProblem = nil
                agent.current?.turns[0].proposal?.status = .stale
            }),
            Scene(name: "09v-attachments-wide", size: CGSize(width: 1440, height: 900), store: { running(page: .agent) },
                  view: AnyView(MainView()), agent: attachmentThread),
            // What Veer asks when a domain with its own group is to go direct.
            Scene(name: "09w-agent-archived", store: { running(page: .agent) }, view: AnyView(MainView()), agent: archivedThread),
            Scene(name: "09y-agent-archived-folded", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                archivedThread(agent)
                agent.selectedID = agent.sessions.first?.id
            }),
            Scene(name: "09x-agent-archived-narrow", size: CGSize(width: 860, height: 560), store: { running(page: .agent) },
                  view: AnyView(MainView()), agent: archivedThread),
            Scene(name: "09r-agent-own-group", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                agent.newThread()
                let conflict = DedicatedGroupRoute.Conflict(group: "mini4k", match: "mini4k.net")
                var turn = Turn(prompt: "mini4k.net 走直连", mode: .ai(model: "qwen3:14b"), steps: [])
                turn.outcome = .clarify(DedicatedGroupRoute.question(for: conflict), options: DedicatedGroupRoute.options(for: conflict))
                agent.current?.turns = [turn]
            }),
            // Five suggestions on the Agent page once pushed the window's content past its top.
            Scene(name: "09j-agent-suggestions", store: {
                let store = running(page: .agent)
                store.suggestions = ["a.example.com", "b.example.com", "c.example.com", "d.example.com"].map { Suggestion(kind: .unmatched(host: $0, count: 5)) }
                    + [Suggestion(kind: .failing(host: "ipv6.itdog.cn", count: 3))]
                return store
            }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            // The route preview with a domain the change does not move, behind a rule that depends on the app.
            Scene(name: "09ad-agent-preview-unsure", store: { running(page: .agent, config: routeSampleConfig) }, view: AnyView(MainView()),
                  agent: previewThread),
            Scene(name: "24p-panel-preview-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(panel: true, config: routeSampleConfig)
                store.agentPanelWidth = 320
                return store
            }, view: AnyView(MainView()), agent: previewThread),
            Scene(name: "09d-agent-applied", store: { running(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }),
            // The meta line open: the steps, their note, then the restatement folded under them.
            Scene(name: "09d-agent-applied-meta-open", store: { running(page: .agent) },
                  view: AnyView(MainView().environment(\.agentMetaStartsOpen, true)), agent: { agent in
                      agent.settings.provider = .ollama
                      sampleThread(agent, status: .written)
                  }),
            Scene(name: "09d-agent-applied-meta-open-narrow", size: CGSize(width: 860, height: 560), store: { running(page: .agent) },
                  view: AnyView(MainView().environment(\.agentMetaStartsOpen, true)), agent: longMetaThread),
            Scene(name: "09d-agent-applied-meta-closed-narrow", size: CGSize(width: 860, height: 560), store: { running(page: .agent) },
                  view: AnyView(MainView()), agent: longMetaThread),
            Scene(name: "09e-agent-undoing", size: CGSize(width: 860, height: 560), store: { running(page: .agent) }, view: AnyView(MainView()),
                  agent: { agent in
                      sampleThread(agent, status: .undone)
                      agent.reversingTurnID = agent.current?.turns.last?.id
                      agent.reversal = .undoing
                  }),
            Scene(name: "09f-agent-undo-failed", store: { running(page: .agent) }, view: AnyView(MainView()), agent: failedReversal),
            Scene(name: "09f-agent-undo-failed-narrow", size: CGSize(width: 860, height: 560), store: { running(page: .agent) },
                  view: AnyView(MainView()), agent: failedReversal),
            Scene(name: "09f-agent-undo-failed-panel", size: CGSize(width: 1440, height: 900), store: { running(panel: true) },
                  view: AnyView(MainView()), agent: failedReversal),
            Scene(name: "09g-agent-undo-profile-removed", size: CGSize(width: 860, height: 560), store: { running(page: .agent) },
                  view: AnyView(MainView()), agent: removedRuntimeProfile),
            Scene(name: "09h-agent-undo-failed-away", store: { running() }, view: AnyView(MainView()), agent: failedReversal),
            Scene(name: "09h-agent-undo-failed-detached", store: { detached() }, view: AnyView(MainView()), agent: failedReversal),
            Scene(name: "24-panel-overview", store: { running(panel: true) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            Scene(name: "24b-panel-setup", store: { running(panel: true) }, view: AnyView(MainView())),
            // The Agent in its own window: the same conversation as `24-panel-overview`.
            Scene(name: "24w-agent-window", size: AgentWindowPlacement.defaultSize, store: { detached() },
                  view: AnyView(AgentWindow(managesWindow: false)), agent: { agent in
                      agent.settings.provider = .ollama
                      sampleThread(agent, status: .pending)
                  }, standardWindow: true),
            Scene(name: "24w-agent-window-smallest", size: AgentWindowPlacement.minimumSize, store: { detached() },
                  view: AnyView(AgentWindow(managesWindow: false)), agent: attachmentThread, standardWindow: true),
            Scene(name: "24w-agent-window-wide", size: CGSize(width: 960, height: 760), store: {
                let store = detached()
                store.suggestions = [Suggestion(kind: .failing(host: "chatgpt.com", count: 3))]
                store.page = .proxies
                return store
            }, view: AnyView(AgentWindow(managesWindow: false)), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }, standardWindow: true),
            Scene(name: "24w-agent-window-setup", size: AgentWindowPlacement.defaultSize, store: { detached() },
                  view: AnyView(AgentWindow(managesWindow: false)), standardWindow: true),
            // The main window meanwhile: the page has its whole width, and the Agent page points to the window.
            Scene(name: "24w-main-detached", store: { detached() }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            Scene(name: "24w-agent-page-detached", store: { detached(page: .agent) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .pending)
            }),
            // Opened after the window is up, as a click does: the window widens and the page keeps its width.
            Scene(name: "24k-panel-opened", store: {
                let store = running()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    store.agentPanel = true
                }
                return store
            }, view: AnyView(MainView()), resizable: true),
            // A window as wide as the screen: no room to widen it, so the panel takes the page's width.
            Scene(name: "24j-panel-screen-wide",
                  size: NSScreen.main.map { CGSize(width: $0.visibleFrame.width, height: 720) } ?? CGSize(width: 1440, height: 720),
                  store: { running(panel: true) }, view: AnyView(MainView()), agent: { agent in
                      agent.settings.provider = .ollama
                      sampleThread(agent, status: .pending)
                  }),
            Scene(name: "24k-panel-wide", size: CGSize(width: 1440, height: 900), store: {
                let store = running(panel: true)
                store.agentPanelWidth = 520
                return store
            }, view: AnyView(MainView()), agent: attachmentThread),
            Scene(name: "24l-panel-sidebar-hidden", store: { running(panel: true) },
                  view: AnyView(MainView(sidebarVisibility: .detailOnly)), agent: { agent in
                      agent.settings.provider = .ollama
                  }),
            Scene(name: "24m-panel-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(panel: true)
                store.agentPanelWidth = 320
                return store
            }, view: AnyView(MainView()), agent: attachmentThread),
            Scene(name: "24n-panel-failed", store: {
                let store = failed(page: .overview)
                store.agentPanel = true
                return store
            }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
            }),
            Scene(name: "24l-panel-widest-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(panel: true)
                store.agentPanelWidth = 520
                return store
            }, view: AnyView(MainView()), agent: attachmentThread),
            Scene(name: "24m-panel-wide-sidebar-hidden", size: CGSize(width: 1440, height: 900), store: { running(panel: true) },
                  view: AnyView(MainView(sidebarVisibility: .detailOnly)), agent: attachmentThread),
            Scene(name: "24c-panel-narrow", size: CGSize(width: 860, height: 640), store: { running(panel: true) }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
            }),
            Scene(name: "24d-panel-connections", store: {
                let store = running(page: .connections, panel: true)
                store.connectionsPaused = true
                store.connections = sampleConnections()
                store.suggestions = [Suggestion(kind: .failing(host: "chatgpt.com", count: 3))]
                return store
            }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }),
            // In full screen the system moves the toolbar to a window of its own, over this one.
            // Each page's narrowest place: the smallest window, with the Agent panel open.
            Scene(name: "24f-narrow-logs", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .logs, panel: true)
                store.logs = sampleLogs()
                return store
            }, view: AnyView(MainView())),
            Scene(name: "24g-narrow-connections", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .connections, panel: true)
                store.connections = sampleConnections()
                return store
            }, view: AnyView(MainView())),
            Scene(name: "24h-narrow-tools", size: CGSize(width: 860, height: 560), store: { running(page: .tools, panel: true) }, view: AnyView(MainView())),
            Scene(name: "24i-narrow-dns", size: CGSize(width: 860, height: 560), store: { running(page: .dns, panel: true) }, view: AnyView(MainView())),
            Scene(name: "24o-narrow-route", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .route, panel: true, config: routeSampleConfig)
                store.routeTestRequest = RouteTestRequest(host: "www.github.com", network: "TCP")
                return store
            }, view: AnyView(MainView())),
            Scene(name: "25-fullscreen-connections-panel", store: {
                let store = sample()
                store.page = .connections
                store.agentPanel = true
                return store
            }, view: AnyView(MainView()), agent: { agent in
                agent.settings.provider = .ollama
                sampleThread(agent, status: .written)
            }, fullScreen: true),
            Scene(name: "25b-fullscreen-proxies", store: { running(page: .proxies) }, view: AnyView(MainView()), fullScreen: true),
            Scene(name: "09e-connections", store: {
                let store = running(page: .connections)
                store.connectionsPaused = true
                store.connections = sampleConnections()
                return store
            }, view: AnyView(MainView())),
            // The domains the model had Veer check, expanded as while the turn runs, at the content
            // width of the default panel and of the narrowest one.
            Scene(name: "09ab-agent-checks", size: CGSize(width: 340, height: 420), store: { running(page: .agent) },
                  view: AnyView(CheckRecordsView(records: sampleChecks(), running: true).padding(Spacing.sm))),
            Scene(name: "09ac-agent-checks-narrow", size: CGSize(width: 280, height: 520), store: { running(page: .agent) },
                  view: AnyView(CheckRecordsView(records: sampleChecks(), running: true).padding(Spacing.sm))),
            Scene(name: "09k-add-rule", size: CGSize(width: 480, height: 420), store: { running(page: .connections) },
                  view: AnyView(AddRuleSheet(row: sampleConnections()[0]))),
            Scene(name: "09g-route-map", size: CGSize(width: 880, height: 240), store: { running(page: .connections) },
                  view: AnyView(RouteMap(row: sampleConnections()[0]) { RouteActions(row: sampleConnections()[0], addRule: {}, close: {}) })),
            // One selected row: its route and actions beside the table.
            Scene(name: "09m-connections-selected", size: CGSize(width: 880, height: 720), store: {
                let store = running(page: .connections)
                store.connectionsPaused = true
                store.connections = sampleConnections()
                return store
            }, view: AnyView(ConnectionsView(selection: [sampleSelectedConnection])
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            // The same in the narrowest column, where the route stacks.
            Scene(name: "09n-connections-selected-narrow", size: CGSize(width: 280, height: 560), store: {
                let store = running(page: .connections)
                store.connections = sampleConnections()
                return store
            }, view: AnyView(ConnectionsView(selection: [sampleSelectedConnection])
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            Scene(name: "09h-requests", store: {
                let store = running(page: .requests)
                store.requests = sampleConnections().enumerated().map { ClosedRequest(row: $1, closedAt: .now.addingTimeInterval(-Double($0) * 7)) }
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09i-dns", store: { running(page: .dns) }, view: AnyView(MainView())),
            // A GEOSITE rule this throwaway folder has no data for, then MATCH: offline, no lookup.
            Scene(name: "09z-route-test", store: {
                let store = running(page: .route, config: routeSampleConfig)
                store.routeTestRequest = RouteTestRequest(host: "www.bilibili.com", network: "TCP")
                return store
            }, view: AnyView(MainView())),
            Scene(name: "04b-overview-suggestions", store: {
                let store = running()
                store.suggestions = [Suggestion(kind: .failing(host: "chatgpt.com", count: 4)),
                                     Suggestion(kind: .slowNode(group: "节点选择", node: "🇺🇸 美国 洛杉矶 01"))]
                return store
            }, view: AnyView(MainView())),
            Scene(name: "09f-logs", store: {
                let store = running(page: .logs)
                store.logs = sampleLogs()
                return store
            }, view: AnyView(MainView())),
            // A level with no entries, which must keep the way back to the others.
            Scene(name: "09l-logs-empty-level", store: {
                let store = running(page: .logs)
                store.logs = sampleLogs()
                return store
            }, view: AnyView(LogsView(level: .debug).background(Color.surface))),
            Scene(name: "10-import", size: CGSize(width: 560, height: 360), store: {
                let store = sample()
                store.importText = "https://sub.example.invalid/api/v1/client/subscribe?token=demo"
                store.importError = String(localized: "找不到这个配置的文件，可能已被删除。")
                return store
            }, view: AnyView(ImportSheet())),
            Scene(name: "11-profile-nodes", size: CGSize(width: 560, height: 520), store: { sample() },
                  view: AnyView(SampleProfileSheet(tab: .nodes))),
            Scene(name: "12-profile-routing", size: CGSize(width: 560, height: 520), store: { sample() },
                  view: AnyView(SampleProfileSheet(tab: .routing))),
            Scene(name: "13-settings-general", size: CGSize(width: 520, height: 360), store: { sample() }, view: AnyView(GeneralSettings())),
            Scene(name: "14b-settings-core", size: CGSize(width: 560, height: 300), store: { sample() }, view: AnyView(CoreSettings())),
            // The Settings window is 560 wide; tall enough for the whole pane.
            Scene(name: "14-settings-proxy", size: CGSize(width: 560, height: 680), store: { sample() }, view: AnyView(ProxySettings())),
            // The validation state: a port below 1024 shows its warning under the port row.
            Scene(name: "14c-settings-proxy-invalid-port", size: CGSize(width: 560, height: 680), store: {
                let store = sample()
                store.settings.mixedPort = 80
                return store
            }, view: AnyView(ProxySettings())),
            Scene(name: "15-overview-tun", store: { running(tun: true) }, view: AnyView(MainView())),
            Scene(name: "18-proxies-map", size: CGSize(width: 900, height: 520), store: { running(page: .proxies) }, view: AnyView(NodeMapView())),
            Scene(name: "18b-proxies-map-page", store: { running(page: .proxies) }, view: AnyView(NodeMapView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            // Beside the Agent panel in the smallest window.
            Scene(name: "18c-proxies-map-narrow", size: CGSize(width: 480, height: 640), store: { running(page: .proxies) }, view: AnyView(NodeMapView().background(Color.surface))),
            Scene(name: "18d-proxies-map-search", store: { running(page: .proxies) }, view: AnyView(NodeMapView(query: "大阪").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            // Every shade, a crowded Europe, a region with no shape, and nodes with no region.
            Scene(name: "18e-proxies-map-many", store: {
                let store = running(page: .proxies)
                typealias Member = ProxyStore.Group.Member
                let counts = [("🇺🇸 美国", 12), ("🇯🇵 日本", 5), ("🇩🇪 德国", 4), ("🇫🇷 法国", 2), ("🇬🇧 英国", 1), ("🇳🇱 荷兰", 1), ("🇭🇰 香港", 8), ("🇹🇼 台湾", 3), ("🇸🇬 新加坡", 4)]
                var members = counts.flatMap { place, count in
                    (1...count).map { Member(name: "\(place) \($0)", delay: place.contains("德国") || place.contains("法国") ? 260 : 90 + $0 * 7, isGroup: false) }
                }
                members += [Member(name: "Relay Alpha", delay: 120, isGroup: false), Member(name: "Relay Beta", delay: nil, isGroup: false)]
                store.groups = [.init(name: "节点选择", type: "Selector", now: "🇺🇸 美国 1", members: members)]
                return store
            }, view: AnyView(NodeMapView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface))),
            // The whole window with the map chosen, on throwaway defaults, for the toolbar's switch.
            // Long names beside the Agent panel: the headers once lost the group's name and the test button.
            Scene(name: "05e-proxies-panel-names", size: CGSize(width: 860, height: 640), store: {
                let store = running(page: .proxies, panel: true)
                store.groups = longNamedGroups
                store.collapsedGroups = ["♻️ 自动选择", "🛑 广告拦截"]
                return store
            }, view: AnyView(MainView()), agent: { $0.settings.provider = .ollama }),
            Scene(name: "05f-proxies-names", store: {
                let store = running(page: .proxies)
                store.groups = longNamedGroups
                store.collapsedGroups = ["♻️ 自动选择", "🛑 广告拦截"]
                return store
            }, view: AnyView(MainView())),
            // Capitals run wider than a count of characters says, and must still clear the toolbar.
            Scene(name: "05d-proxies-latin-name-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .proxies)
                if let index = store.profiles.firstIndex(where: { $0.id == store.activeProfileID }) {
                    store.profiles[index].name = "MOMENTUM NETWORK PREMIUM"
                }
                return store
            }, view: AnyView(MainView())),
            Scene(name: "18f-proxies-map-window", store: { running(page: .proxies) }, view: AnyView(MainView().defaultAppStorage(mapDefaults()))),
            Scene(name: "18g-proxies-map-window-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .proxies)
                store.agentPanel = true
                return store
            }, view: AnyView(MainView().defaultAppStorage(mapDefaults()))),
            Scene(name: "18h-proxies-map-window-wide", size: CGSize(width: 1440, height: 900), store: { running(page: .proxies) },
                  view: AnyView(MainView().defaultAppStorage(mapDefaults()))),
            Scene(name: "18i-proxies-map-filtered-region", size: CGSize(width: 360, height: 540), store: { running(page: .proxies) },
                  view: AnyView(NodeMapView(query: "香港").background(Color.surface))),
            Scene(name: "18j-proxies-map-testing", size: CGSize(width: 360, height: 540), store: {
                let store = running(page: .proxies)
                store.testingScopes.insert(.region("JP"))
                for member in store.groups.flatMap(\.members) where store.region(of: member.name) == "JP" { store.delays[member.name] = .testing }
                return store
            }, view: AnyView(NodeMapView().background(Color.surface))),
            Scene(name: "18k-proxies-map-no-results", size: CGSize(width: 360, height: 540), store: { running(page: .proxies) },
                  view: AnyView(NodeMapView(query: "Relay K9", clearSearch: {}).background(Color.surface))),
            // A search that finds nothing, in the window: the grid, the map, and the map beside the panel.
            Scene(name: "18m-proxies-grid-no-results", store: { running(page: .proxies) },
                  view: AnyView(MainView().environment(\.proxiesStartingQuery, "Relay K9"))),
            Scene(name: "18n-proxies-map-window-no-results", store: { running(page: .proxies) },
                  view: AnyView(MainView().defaultAppStorage(mapDefaults()).environment(\.proxiesStartingQuery, "Relay K9"))),
            Scene(name: "18o-proxies-map-no-results-smallest", size: CGSize(width: 860, height: 560), store: {
                let store = running(page: .proxies)
                store.agentPanel = true
                return store
            }, view: AnyView(MainView().defaultAppStorage(mapDefaults()).environment(\.proxiesStartingQuery, "Relay K9"))),
            Scene(name: "18l-proxies-map-test-failed", size: CGSize(width: 360, height: 540), store: {
                let store = running(page: .proxies)
                for member in store.groups.flatMap(\.members) where store.region(of: member.name) == "JP" {
                    store.delays[member.name] = .failed("DNS lookup")
                }
                return store
            }, view: AnyView(NodeMapView().background(Color.surface))),
            Scene(name: "04j-overview-wide", size: CGSize(width: 1440, height: 900), store: { running() }, view: AnyView(MainView())),
            Scene(name: "19-profiles-update-failed", store: {
                let store = running(page: .proxies)
                if let first = store.profiles.first {
                    let reason = String(localized: "无法下载订阅：网络错误或超时。")
                    store.activity = Activity(profileID: first.id, name: first.name, kind: .failed(reason))
                }
                return store
            }, view: AnyView(MainView())),
            Scene(name: "19a-profiles-sheet-update-failed", size: CGSize(width: 520, height: 520), store: {
                let store = sample()
                if let first = store.profiles.first, let link = URL(string: "https://subscription.example.invalid/config") {
                    let copy = Profile(name: "东京备用订阅 Tokyo Backup", isSubscription: true, nodeCount: 5)
                    try? store.profileStore.save(copy, text: sampleConfig)
                    try? store.profileStore.setSubscriptionURL(link, for: first.id)
                    try? store.profileStore.setSubscriptionURL(link, for: copy.id)
                    store.profiles = store.profileStore.loadAll()
                    let reason = String(localized: "无法下载订阅：网络错误或超时。")
                    store.activity = Activity(profileID: first.id, name: first.name, kind: .failed(reason))
                }
                return store
            }, view: AnyView(ProfilesSheet())),
            // The Agent's toast with Undo, over a page with the Agent hidden: green text on glass (`accentOnGlass`).
            Scene(name: "19b-toast-undo", store: { running(page: .overview) }, view: AnyView(MainView()), agent: { agent in
                agent.toast = Toast(message: String(localized: "已应用 \(2) 项修改，内核已生效"), undoable: true)
            }),
            Scene(name: "21-profile-check", size: CGSize(width: 560, height: 520), store: { sample() },
                  view: AnyView(SampleProfileSheet(tab: .check))),
            Scene(name: "22-settings-shortcuts", size: CGSize(width: 560, height: 320), store: { sample() }, view: AnyView(HotKeySettings())),
            Scene(name: "23-settings-about", size: CGSize(width: 560, height: 320), store: { sample() }, view: AnyView(AboutSettings())),
            Scene(name: "20-profile-template", size: CGSize(width: 560, height: 520), store: {
                let store = sample()
                if let id = store.profiles.first?.id { store.setTemplate(RuleTemplate.standard, for: id) }
                return store
            }, view: AnyView(SampleProfileSheet(tab: .routing))),
            // The failure state: an edit whose exit the refreshed subscription no longer has.
            Scene(name: "20b-profile-routing-conflict", size: CGSize(width: 560, height: 520), store: { routingConflictStore(template: false) },
                  view: AnyView(SampleProfileSheet(tab: .routing))),
            Scene(name: "20c-profile-template-conflict", size: CGSize(width: 560, height: 520), store: { routingConflictStore(template: true) },
                  view: AnyView(SampleProfileSheet(tab: .routing))),
            // Just after switching the rules with the core stopped: no config built yet, so the tab
            // replays the edits itself and the lost exit's warning comes back.
            Scene(name: "20d-profile-template-replay-stopped", size: CGSize(width: 560, height: 520), store: {
                let store = routingConflictStore(template: true)
                store.effective = nil
                return store
            }, view: AnyView(SampleProfileSheet(tab: .routing))),
            Scene(name: "16-settings-tun-approval", size: CGSize(width: 560, height: 460), store: {
                let store = sample()
                store.settings.tun = true
                store.helperProbe = { .needsApproval }
                store.notice = String(localized: "TUN 未能启动，已改用系统代理。\(String(localized: "需要在系统设置的“登录项”中允许 Veer 的后台服务。"))")
                return store
            }, view: AnyView(TUNSettings())),
            Scene(name: "17-settings-tun-ready", size: CGSize(width: 560, height: 420), store: {
                let store = sample()
                store.settings.tun = true
                store.helperProbe = { .ready }
                return store
            }, view: AnyView(TUNSettings())),
        ] + sidebarScenes() + appRoutingScenes()
    }

    static func sampleConnections() -> [ConnectionRow] {
        typealias Connection = MihomoController.Connection
        let now = Date()
        let rows: [(String, String?, String, String, [String], Int64, Int64, Int64, TimeInterval)] = [
            ("www.youtube.com", "Google Chrome", "RuleSet", "youtube", ["🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路", "节点选择"], 182_000, 48_300_000, 2_400_000, 95),
            ("api.github.com", "git", "DomainSuffix", "github.com", ["🇭🇰 香港 01", "自动选择", "节点选择"], 3_200, 21_000, 0, 12),
            ("chatgpt.com", "Safari", "RuleSet", "openai", ["🇺🇸 美国 洛杉矶 01", "节点选择"], 64_000, 1_250_000, 31_000, 340),
            ("www.apple.com", "Safari", "DomainSuffix", "apple.com", ["DIRECT"], 1_800, 9_400, 0, 4),
            ("api.telegram.org", "Telegram", "RuleSet", "telegram", ["🇸🇬 新加坡 01", "节点选择"], 22_000, 18_000, 120, 1_830),
            ("149.154.167.51:443", "Telegram", "Match", "", ["🇸🇬 新加坡 01", "节点选择"], 4_000, 2_000, 0, 60),
        ]
        return rows.enumerated().map { index, row in
            let connection = Connection(id: "c\(index)", metadata: .init(network: "tcp", host: row.0.contains(":") ? "" : row.0,
                                                                        destinationIP: row.0.contains(":") ? "149.154.167.51" : nil,
                                                                        destinationPort: "443", process: row.1),
                                        chains: row.4, rule: row.2, rulePayload: row.3, upload: row.5, download: row.6,
                                        start: now.addingTimeInterval(-row.8))
            return ConnectionRow(connection, uploadRate: row.7 / 20, downloadRate: row.7)
        }
    }

    static var sampleSelectedConnection: ConnectionRow.ID { sampleConnections()[0].id }

    static func sampleLogs() -> [LogEntry] {
        [
            LogEntry(level: "info", message: "[TCP] 127.0.0.1:52344(Google Chrome) --> www.youtube.com:443 match RuleSet(youtube) using 节点选择[🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路]"),
            LogEntry(level: "info", message: "[TCP] 127.0.0.1:52350(git) --> api.github.com:443 match DomainSuffix(github.com) using 节点选择[🇭🇰 香港 01]"),
            LogEntry(level: "warning", message: "[TCP] dial 节点选择 (match RuleSet/openai) 127.0.0.1:52361(Safari) --> chatgpt.com:443 error: i/o timeout"),
            LogEntry(level: "info", message: "[TCP] 127.0.0.1:52370(Safari) --> www.apple.com:443 match DomainSuffix(apple.com) using DIRECT"),
            LogEntry(level: "error", message: "[Provider] reject-list pull error: Get \"https://cdn.jsdelivr.net/…\": context deadline exceeded"),
            LogEntry(level: "info", message: "[UDP] 127.0.0.1:61502(Google Chrome) --> www.youtube.com:443 match AND((NETWORK,UDP),(DST-PORT,443)) using REJECT"),
        ]
    }

    /// A conversation about the sample profile with one proposal: Netflix to the Japan node.
    /// A conversation whose profile was deleted, selected, below a current one.
    private static func archivedThread(_ agent: AgentStore) {
        agent.settings.provider = .ollama
        sampleThread(agent, status: .pending)
        guard let archived = agent.sessions.first?.id else { return }
        agent.sessions[0].profileID = UUID()
        agent.newThread()
        agent.selectedID = archived
    }

    /// The Netflix proposal, with a domain the AI checked that the change leaves where it was.
    private static func previewThread(_ agent: AgentStore) {
        agent.settings.provider = .ollama
        sampleThread(agent, status: .pending)
        guard !agent.sessions.isEmpty, !agent.sessions[0].turns.isEmpty else { return }
        agent.sessions[0].turns[0].checks = [CheckRecord(domain: "www.google.com", ruleIndex: nil, rule: nil, target: nil, certain: false,
                                                         note: nil, sets: [], address: nil)]
    }

    private static func failedReversal(_ agent: AgentStore) {
        sampleThread(agent, status: .undone)
        guard let id = agent.selectedID else { return }
        let reason = String(localized: "无法下载订阅：网络错误或超时。")
        let message = String(localized: "撤销已保存，但内核没有重新载入：\(reason)")
        agent.finishReversal(message, redo: false, sessionID: id, warning: true)
    }

    private static func removedRuntimeProfile(_ agent: AgentStore) {
        sampleThread(agent, status: .undone)
        var run = RuntimeRun(steps: [.mode("direct")], profileID: UUID())
        run.items[0].state = .done
        run.items[0].undo = .mode("rule")
        run.items[0].result = String(localized: "已切换到\(ProxyStore.Mode.direct.title)模式")
        let turn = Turn(prompt: "切换到直连模式", mode: .local, steps: [], outcome: .runtime(run))
        agent.current?.turns = [turn]
    }

    private static func longMetaThread(_ agent: AgentStore) {
        agent.settings.provider = .ollama
        let understanding = String(localized: "把 Netflix 相关域名的流量交给日本节点。保留现有规则的顺序和其他服务的分流，让本地设备仍可访问。如果之后切换了出口，先检查已保存的规则再继续修改。")
        sampleThread(agent, status: .written, understanding: understanding)
    }

    static func sampleThread(_ agent: AgentStore, status: Turn.ProposalStatus, understanding: String = "把 Netflix 的流量交给日本节点") {
        guard let profile = agent.proxy.activeProfile, let text = try? agent.proxy.effectiveText(of: profile.id),
              let document = try? ConfigDocument.parse(text), let target = document.target(named: "🇯🇵 日本 大阪 02") else { return }
        let plan = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: "netflix.com", targetId: target.id),
                                         .route(matchType: "DOMAIN-SUFFIX", match: "nflxvideo.net", targetId: target.id)])
        guard let result = try? PlanApplier.apply(plan, to: document) else { return }
        var session = Session(title: "Netflix 走日本", source: .pasted, text: text)
        session.profileID = profile.id
        session.exitsConfirmed = true
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .done) }
        var turn = Turn(prompt: "Netflix 走日本", mode: .ai(model: "qwen3:14b"), steps: steps, outcome: .proposal(.init(
            plan: plan, items: result.items, accepted: Set(result.items.map(\.id)), baseDraft: text, candidate: result.candidate,
            validation: ValidationResult(status: .passed, message: String(localized: "Mihomo 校验通过")), status: status)))
        turn.understanding = understanding
        turn.duration = 3.2
        session.turns = [turn]
        agent.sessions = [session]
        agent.selectedID = session.id
    }

    /// Checks against the route sample's rules, with no geodata: a certain hit, and one behind rules
    /// that depend on the app and on GeoSite data.
    static func sampleChecks() -> [CheckRecord] {
        guard let rules = try? ConfigDocument.parse(routeSampleConfig).rules else { return [] }
        let domains: [(String, [String])] = [("chat.openai.com", ["openai"]), ("upos-sz-mirrorcos.bilivideo.com", ["bilibili", "cn"])]
        return domains.compactMap { domain, sets in
            guard let query = RouteQuery(domain, port: 443, network: .tcp) else { return nil }
            return DomainChecker.record(domain, trace: RouteTracer.trace(query, rules: rules, data: RouteData()), sets: sets)
        }
    }

    /// The sample profile in use, with one enabled edit to a group the profile no longer has and one
    /// that still applies, as after a subscription refresh dropped “美国专线”.
    static func routingConflictStore(template: Bool) -> ProxyStore {
        let store = sample()
        guard let id = store.profiles.first?.id else { return store }
        store.activeProfileID = id
        let base = sampleConfig.replacingOccurrences(of: "proxy-groups:\n", with: "proxy-groups:\n  - {name: 美国专线, type: select, proxies: [🇺🇸 美国 洛杉矶 01]}\n")
        func edit(_ prompt: String, _ target: String, _ match: String, _ base: String) -> RoutingLayer.Edit? {
            guard let document = try? ConfigDocument.parse(base), let targetID = document.target(named: target)?.id else { return nil }
            let plan = EditPlan(operations: [.route(matchType: "DOMAIN-SUFFIX", match: match, targetId: targetID)])
            guard let result = try? PlanApplier.apply(plan, to: document) else { return nil }
            return RoutingLayer.Edit(createdAt: .now.addingTimeInterval(-86400), source: .agent, prompt: prompt, plan: plan,
                                     accepted: [0], items: result.items, base: base)
        }
        var layer = RoutingLayer(edits: [edit("Hulu 走美国专线", "美国专线", "hulu.com", base),
                                         edit("Netflix 走节点选择", "节点选择", "netflix.com", sampleConfig)].compactMap { $0 })
        if template { layer.template = RuleTemplate.standard }
        try? store.routingStore.save(layer, for: id)
        store.effective = try? layer.apply(to: sampleConfig)
        return store
    }

    /// The node sheet for the sample's first profile.
    struct SampleProfileSheet: View {
        @Environment(ProxyStore.self) private var store
        let tab: ProfileDetailSheet.Tab

        var body: some View {
            if let profile = store.profiles.first { ProfileDetailSheet(profile: profile, tab: tab) }
        }
    }

    static let sampleConfig = """
    proxies:
      - {name: 🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路, type: ss, server: jp1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇯🇵 日本 大阪 02, type: ss, server: jp2.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇭🇰 香港 01, type: ss, server: hk1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇺🇸 美国 洛杉矶 01, type: ss, server: us1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
      - {name: 🇸🇬 新加坡 01, type: ss, server: sg1.example.invalid, port: 1, cipher: aes-128-gcm, password: p}
    proxy-groups:
      - {name: 节点选择, type: select, proxies: [🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路, 🇯🇵 日本 大阪 02, 🇭🇰 香港 01, 🇺🇸 美国 洛杉矶 01, 🇸🇬 新加坡 01]}
    rules:
      - MATCH,节点选择
    """

    /// The sample with the rules a route test shows: by domain, by the app, by geodata, a QUIC block.
    static let routeSampleConfig = sampleConfig.replacingOccurrences(of: "  - MATCH,节点选择", with: """
      - DOMAIN-SUFFIX,openai.com,节点选择
      - DOMAIN-SUFFIX,github.com,节点选择
      - PROCESS-NAME,Telegram,节点选择
      - GEOSITE,cn,DIRECT
      - GEOIP,CN,DIRECT,no-resolve
      - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
      - MATCH,节点选择
    """)

    private static func profilesWithDuplicates(protected: Bool = false) -> ProxyStore {
        let store = sample()
        guard let original = store.activeProfile,
              let link = URL(string: "https://subscription.example.invalid/tokyo") else { return store }
        let backup = Profile(name: "东京备用订阅 Tokyo Backup", isSubscription: true, nodeCount: 5)
        try? store.profileStore.save(backup, text: sampleConfig)
        try? store.profileStore.setSubscriptionURL(link, for: original.id)
        try? store.profileStore.setSubscriptionURL(link, for: backup.id)
        if protected { try? store.routingStore.save(RoutingLayer(excludedNodes: ["🇸🇬 新加坡 01"]), for: backup.id) }
        store.profiles = store.profileStore.loadAll()
        return store
    }

    private static func removedProfileSamples(count: Int = 2) -> [RemovedProfile] {
        ["Tokyo Backup", "Sydney Backup"].prefix(count).map { name in
            RemovedProfile(profile: Profile(name: name, isSubscription: true, nodeCount: 5), text: sampleConfig,
                           link: URL(string: "https://subscription.example.invalid/config")!)
        }
    }

    static func sample(profiles: Bool = true, config: String = sampleConfig) -> ProxyStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veer-snapshot-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "veer-snapshot-\(UUID().uuidString)")!
        // Scenes that want the Agent panel say so.
        defaults.set(false, forKey: "agentPanel")
        let paths = VeerPaths(root: root)
        if profiles {
            let hour: TimeInterval = 3600
            let store = ProfileStore(paths: paths, secrets: FileKeyStore(url: paths.secrets))
            try? store.save(Profile(name: "我的机场 · 高速专线（这是一个很长的订阅名称，用来检查截断）", isSubscription: true,
                                    updatedAt: .now.addingTimeInterval(-2 * hour), nodeCount: 5,
                                    usage: SubscriptionUsage(upload: 3 << 30, download: 57 << 30, total: 200 << 30, expire: nil)), text: config)
            try? store.save(Profile(name: "家里的路由器", isSubscription: false, updatedAt: .now.addingTimeInterval(-30 * 24 * hour), nodeCount: 3),
                            text: sampleConfig)
            if let first = store.loadAll().first {
                try? RoutingStore(paths: paths).save(RoutingLayer(excludedNodes: ["🇸🇬 新加坡 01"]), for: first.id)
            }
        }
        return ProxyStore(paths: paths, systemProxy: SystemProxy(runner: { _ in "" }), binary: nil, defaults: defaults)
    }

    static func failed(page: Page) -> ProxyStore {
        let store = sample()
        store.page = page
        store.phase = .failed(String(localized: "端口 \(String(7890)) 已被其他程序占用。退出占用它的代理软件，或在设置中换一个端口。"), log: [
            "time=\"2026-10-29T10:00:00+08:00\" level=info msg=\"Start initial configuration in progress\"",
            "level=error msg=\"Start Mixed(http+socks) server error: listen tcp 127.0.0.1:7890: bind: address already in use\"",
        ])
        return store
    }

    static func controllerPortTaken() -> ProxyStore {
        let store = sample()
        store.phase = .failed(ProxyStore.message(for: .controller(31377)), log: [
            "time=\"2026-10-29T10:00:00+08:00\" level=info msg=\"Mixed(http+socks) proxy listening at: 127.0.0.1:7890\"",
            "time=\"2026-10-29T10:00:00+08:00\" level=error msg=\"External controller listen error: listen tcp 127.0.0.1:31377: bind: address already in use\"",
        ])
        return store
    }

    static func detached(page: Page = .overview) -> ProxyStore {
        let store = running(page: page)
        store.agentPresentation = .detached
        return store
    }

    static func stopped(page: Page) -> ProxyStore {
        let store = sample()
        store.page = page
        return store
    }

    static func running(page: Page = .overview, tun: Bool = false, panel: Bool = false, lan: Bool = false, config: String = sampleConfig) -> ProxyStore {
        let store = sample(config: config)
        store.agentPanel = panel
        // Before the phase: turning TUN on in a running store restarts the core.
        store.settings.tun = tun
        store.settings.allowLAN = lan
        store.tunActive = tun
        store.page = page
        store.phase = .running
        store.systemProxyOn = true
        store.exit = ExitInfo(ip: "203.0.113.7", country: "Japan", countryCode: "JP", organization: "DATAWAVE GLOBAL LLC")
        store.runningSince = .now.addingTimeInterval(-600)
        store.uploadRate = 42 << 10
        store.downloadRate = 3 << 20
        typealias Member = ProxyStore.Group.Member
        store.groups = [
            .init(name: "节点选择", type: "Selector", now: "🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路", members: [
                Member(name: "自动选择", delay: 86, isGroup: true),
                Member(name: "🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路", delay: 92, isGroup: false),
                Member(name: "🇯🇵 日本 大阪 02", delay: 412, isGroup: false),
                Member(name: "🇭🇰 香港 01", delay: 38, isGroup: false),
                Member(name: "🇺🇸 美国 洛杉矶 01", delay: 0, isGroup: false),
                Member(name: "🇸🇬 新加坡 01", delay: nil, isGroup: false),
                Member(name: "DIRECT", delay: nil, isGroup: false),
            ]),
            .init(name: "自动选择", type: "URLTest", now: "🇭🇰 香港 01", members: [
                Member(name: "🇭🇰 香港 01", delay: 38, isGroup: false),
                Member(name: "🇯🇵 日本 大阪 02", delay: 412, isGroup: false),
                Member(name: "🇺🇸 美国 洛杉矶 01", delay: 1260, isGroup: false),
            ]),
            .init(name: "Netflix", type: "Selector", now: "🇯🇵 日本 大阪 02", members: [
                Member(name: "节点选择", delay: nil, isGroup: true),
                Member(name: "🇯🇵 日本 大阪 02", delay: 412, isGroup: false),
            ]),
        ]
        return store
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Into full screen and out again, with a picture of everything this app shows in between: the
    /// toolbar's own full-screen window is above `window`, so capturing that alone would leave it out.
    static func captureFullScreen(_ window: NSWindow, to url: URL) async {
        window.styleMask.insert(.resizable)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2))
        // Core Graphics counts from the top of the main screen. optionOnScreenAboveWindow = 1 << 1,
        // optionIncludingWindow = 1 << 3, bestResolution = 1 << 3.
        let flipped = (NSScreen.screens.first?.frame.height ?? 0) - window.frame.maxY
        let bounds = CGRect(x: window.frame.minX, y: flipped, width: window.frame.width, height: window.frame.height)
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            if let image = function(bounds, (1 << 1) | (1 << 3), UInt32(window.windowNumber), 1 << 3)?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        // What covers what, for a check that does not depend on reading the picture.
        let layout = NSApp.windows.filter(\.isVisible).map { shown in
            "\(type(of: shown)) \(shown.frame) level \(shown.level.rawValue) toolbar \(shown.toolbar?.isVisible.description ?? "none")"
                + " mouse \(!shown.ignoresMouseEvents) alpha \(shown.alphaValue) opaque \(shown.isOpaque) number \(shown.windowNumber)"
        }
        let top = NSWindow.windowNumber(at: CGPoint(x: window.frame.maxX - 60, y: window.frame.maxY - 20), belowWindowWithWindowNumber: 0)
        let notes = url.deletingPathExtension().appendingPathExtension("txt")
        try? (["content \(window.contentLayoutRect)", "frontmost in the row \(top), this window \(window.windowNumber)"] + layout).joined(separator: "\n")
            .write(to: notes, atomically: true, encoding: .utf8)
        // ⌘F finds the field by where it is in the window, which full screen changes.
        ToolbarSearchFocus.focus()
        let searching = "search field focused \(window.firstResponder is NSTextView)"
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2))
        // And the toolbar is back for the ordinary window.
        let after = "after leaving: toolbar \(window.toolbar?.isVisible.description ?? "none"), content \(window.contentLayoutRect)"
        let layoutNotes = (try? String(contentsOf: notes, encoding: .utf8)) ?? ""
        try? [searching, after, layoutNotes].joined(separator: "\n").write(to: notes, atomically: true, encoding: .utf8)
        capture(window, to: url.deletingPathExtension().appendingPathExtension("left.png"))
    }

    /// The window as the screen shows it (sidebar material included); falls back to drawing the
    /// view hierarchy, which leaves vibrancy out.
    private typealias WindowsImageFunction = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    static func capture(_ window: NSWindow, to url: URL) {
        // With the Agent panel's window beside it, both, as one picture.
        if let children = window.childWindows, !children.isEmpty,
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") {
            let function = unsafeBitCast(symbol, to: WindowsImageFunction.self)
            // The array holds window numbers as its values, not objects.
            // The image API composites front to back, so an overlapping child precedes its parent.
            var ids = (children.reversed() + [window]).map { UnsafeRawPointer(bitPattern: $0.windowNumber) }
            if let array = CFArrayCreate(nil, &ids, ids.count, nil),
               let image = function(.null, array, (1 << 0) | (1 << 3))?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
            // optionIncludingWindow = 1 << 3; boundsIgnoreFraming = 1 << 0, bestResolution = 1 << 3
            if let image = function(.null, 1 << 3, UInt32(window.windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
        }
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

// App Routing scenes: sample data, in this file so it stays out of the localization scan.
extension SnapshotRunner {
    /// App Routing: the view at each window size, its empty and not-in-effect states, the app picker,
    /// a connection that hit an app rule, and the Agent's proposal card. Apps are read from this Mac's
    /// own folders (read-only), so icons and helpers are real; one rule points at an app that is gone.
    static func appRoutingScenes() -> [Scene] {
        func window() -> AnyView { AnyView(MainView().defaultAppStorage(appRoutingDefaults())) }
        return [
            Scene(name: "40-app-routing", store: { appRoutingStore() }, view: window()),
            Scene(name: "40b-app-routing-smallest", size: CGSize(width: 860, height: 560), store: { appRoutingStore() },
                  view: window()),
            Scene(name: "40c-app-routing-wide", size: CGSize(width: 1440, height: 900), store: { appRoutingStore() },
                  view: window()),
            Scene(name: "40d-app-routing-panel", store: { appRoutingStore(panel: true) }, view: window()),
            // The narrowest page: the smallest window beside the panel, where each row takes two lines.
            Scene(name: "40h-app-routing-panel-smallest", size: CGSize(width: 860, height: 560), store: { appRoutingStore(panel: true) },
                  view: window()),
            Scene(name: "40e-app-routing-empty", store: { appRoutingStore(rules: false) }, view: window()),
            Scene(name: "40f-app-routing-global", store: {
                let store = appRoutingStore()
                store.mode = .global
                return store
            }, view: window()),
            Scene(name: "40g-app-routing-stopped", store: { appRoutingStore(running: false) }, view: window()),
            Scene(name: "41-app-picker", size: CGSize(width: 560, height: 560), store: {
                let store = appRoutingStore()
                store.loadApps()
                return store
            }, view: AnyView(AppPickerSheet(existing: [], targets: (["节点选择", "自动选择", "Netflix"], ["🇭🇰 香港 01"])) { _, _ in })),
            Scene(name: "42-connections-app-rule", store: {
                let store = appRoutingStore(page: .connections)
                store.connectionsPaused = true
                store.connections = sampleAppConnections()
                return store
            }, view: AnyView(ConnectionsView(selection: ["app-0"]))),
            Scene(name: "43-agent-app-proposal", store: { appRoutingStore(page: .agent) }, view: AnyView(MainView()), agent: appProposalThread),
        ]
    }

    static func appRoutingDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "veer-snapshot-\(UUID().uuidString)")!
        defaults.set(true, forKey: "proxiesShowApps")
        return defaults
    }

    /// Apps found on this Mac where they exist, else stand-ins at the usual paths.
    static func sampleApps() -> [AppIdentity] {
        let names = ["Google Chrome", "Claude", "Safari", "Ghostty"]
        var apps = names.map { name in
            AppDiscovery.identity(ofBundle: URL(fileURLWithPath: "/Applications/\(name).app"))
                ?? AppIdentity(kind: .bundle, name: name, bundlePath: "/Applications/\(name).app",
                               executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)")
        }
        apps.append(AppIdentity(kind: .executable, name: "curl", executablePath: "/usr/bin/curl", flavor: .commandLine))
        apps.append(AppIdentity(kind: .bundle, name: "旧版聊天工具", bundleID: "com.example.oldchat", bundlePath: "/Applications/OldChat.app",
                                executablePath: "/Applications/OldChat.app/Contents/MacOS/OldChat", flavor: .electron))
        return apps
    }

    static func appRoutingStore(page: Page = .proxies, rules: Bool = true, running: Bool = true, panel: Bool = false) -> ProxyStore {
        let store = running ? self.running(page: page, panel: panel) : sample()
        store.page = page
        guard rules, let id = store.activeProfileID else { return store }
        let apps = sampleApps()
        var layer = store.routingStore.load(id)
        layer.appRules = [
            AppRule(app: apps[0], target: .policy("节点选择"),
                    domains: [.init(matchType: "DOMAIN-SUFFIX", value: "bank.example.cn", target: .direct)]),
            AppRule(app: apps[1], target: .policy("🇯🇵 日本 大阪 02")),
            AppRule(app: apps[2], target: .policy("🇺🇸 美国 洛杉矶 01")),
            AppRule(app: apps[4], target: .direct),
            AppRule(app: apps[3], target: .reject, enabled: false),
            AppRule(app: apps[5], target: .policy("已删除的策略组")),
        ]
        try? store.routingStore.save(layer, for: id)
        // As the core's start does: the route map reads which app rule a connection hit from it.
        _ = try? store.effectiveText(of: id)
        store.appRoutingFocus = apps[0].id
        store.runningApps = [apps[0], apps[1]]
        return store
    }

    static func sampleAppConnections() -> [ConnectionRow] {
        typealias Connection = MihomoController.Connection
        let chrome = sampleApps()[0], helper = chrome.helpers.first?.path ?? chrome.executablePath
        struct Sample {
            let host: String, process: String, path: String, rule: String, payload: String, chain: [String]
        }
        let rows = [
            Sample(host: "www.youtube.com", process: URL(fileURLWithPath: helper).lastPathComponent, path: helper, rule: "ProcessPathWildcard",
                   payload: chrome.root + "/*", chain: ["🇯🇵 日本 东京 IPLC 01 | 0.5x 高速稳定线路", "节点选择"]),
            Sample(host: "updates.example.org", process: "curl", path: "/usr/bin/curl", rule: "ProcessPath", payload: "/usr/bin/curl", chain: ["DIRECT"]),
            Sample(host: "www.apple.com", process: "com.apple.WebKit.Networking",
                   path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/"
                       + "com.apple.WebKit.Networking", rule: "DomainSuffix", payload: "apple.com", chain: ["DIRECT"]),
        ]
        return rows.enumerated().map { index, row in
            let connection = Connection(id: "app-\(index)", metadata: .init(network: "tcp", host: row.host, destinationPort: "443",
                                                                           process: row.process, processPath: row.path),
                                        chains: row.chain, rule: row.rule, rulePayload: row.payload, upload: 4_000, download: 210_000,
                                        start: .now.addingTimeInterval(-Double(30 * (index + 1))))
            return ConnectionRow(connection, uploadRate: 200, downloadRate: 8_000)
        } + sampleConnections()
    }

    /// "Chrome 走日本，curl 直连": the Agent's proposal, pending, checked by Mihomo.
    static func appProposalThread(_ agent: AgentStore) {
        agent.settings.provider = .ollama
        guard let profile = agent.proxy.activeProfile, let text = try? agent.proxy.effectiveText(of: profile.id) else { return }
        let apps = sampleApps()
        var session = Session(title: "Chrome 走日本，curl 直连", source: .pasted, text: text)
        session.profileID = profile.id
        session.exitsConfirmed = true
        let steps = EditorEngine.stepTitles.enumerated().map { Turn.Step(id: $0.offset, title: $0.element, state: .done) }
        var proposal = AppRoutingProposal(changes: [AppRouteChange(app: apps[0], target: .policy("🇯🇵 日本 大阪 02")),
                                                    AppRouteChange(app: apps[2], target: .direct),
                                                    AppRouteChange(app: apps[4], target: nil, remove: true)],
                                          profileID: profile.id)
        proposal.validation = ValidationResult(status: .passed, message: "")
        var turn = Turn(prompt: "Chrome 走大阪节点，Safari 直连，curl 的规则删掉", mode: .ai(model: "qwen3:14b"), steps: steps,
                        outcome: .appRouting(proposal))
        turn.understanding = "按应用分流：Chrome 走日本大阪节点，Safari 直连，删除 curl 的应用规则。"
        turn.duration = 2.4
        session.turns = [turn]
        agent.sessions = [session]
        agent.selectedID = session.id
    }
}
