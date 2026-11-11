import SwiftUI

extension SnapshotRunner {
    /// Native sidebar endpoints, including the first layout with the sidebar already hidden.
    static func sidebarScenes() -> [Scene] {
        var scenes: [Scene] = []
        for width in [860, 1080, 1440] {
            for panel in [false, true] where !panel || width != 1440 {
                for page in [Page.overview, .proxies, .connections] {
                    for hidden in [false, true] {
                        let name = "86-\(page.rawValue)-\(width)-\(panel ? "panel" : "page")-\(hidden ? "hidden" : "shown")"
                        let height = width == 860 ? 560 : width == 1440 ? 900 : 720
                        scenes.append(Scene(name: name, size: CGSize(width: width, height: height), store: {
                            let store = running(page: page, panel: panel)
                            store.connectionsPaused = true
                            store.connections = sampleConnections()
                            return store
                        }, view: AnyView(MainView(sidebarVisibility: hidden ? .detailOnly : .all))))
                    }
                }
            }
        }
        scenes += [
            Scene(name: "87-failed-onboarding", size: CGSize(width: 860, height: 560), store: {
                let store = recoverySample()
                store.onboarding = .start
                return store
            }, view: AnyView(MainView())),
            Scene(name: "87-failed-updating-panel", size: CGSize(width: 860, height: 560), store: {
                let store = recoverySample()
                store.agentPanel = true
                if let id = store.activeProfileID { store.updatingProfiles.insert(id) }
                return store
            }, view: AnyView(MainView())),
            Scene(name: "87-failed-local-profile", size: CGSize(width: 860, height: 560), store: {
                let store = recoverySample()
                store.page = .proxies
                store.activeProfileID = store.profiles.last?.id
                return store
            }, view: AnyView(MainView())),
        ]
        return scenes
    }

    private static func recoverySample() -> ProxyStore {
        let store = sample()
        store.phase = .failed(String(localized: "策略组“\("♻️ 自动选择")”没有节点或 Provider，无法启动。请更新订阅或换用有效配置；本地配置可在“编辑成员”中修复。"), log: [])
        store.notice = String(localized: "无法下载订阅：网络错误或超时。")
        return store
    }
}
