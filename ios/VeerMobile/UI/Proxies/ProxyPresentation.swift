import SwiftUI
import VeerCore

/// Presentation only; selection, delay testing and region assignments remain in ProxyStore.
enum ProxyPresentation {
    static func typeLabel(_ type: String) -> String {
        switch type {
        case "Selector": String(localized: "手动选择")
        case "URLTest": String(localized: "自动选择")
        case "Fallback": String(localized: "故障转移")
        case "LoadBalance": String(localized: "负载均衡")
        case "Relay": String(localized: "链式")
        default: type
        }
    }

    static func nodeName(_ name: String, isNode: Bool, store: ProxyStore) -> String {
        guard isNode, !NodeLocator.hasFlag(name),
              let code = store.region(of: name), let place = NodeLocator.place(code) else { return name }
        return "\(place.flag) \(name)"
    }

    static func spokenDelay(_ delay: Int?) -> String {
        guard let delay else { return String(localized: "未测速") }
        guard delay > 0 else { return String(localized: "超时") }
        return Measurement(value: Double(delay), unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .wide, usage: .asProvided))
    }
}

/// Used by both screens so a pushed detail never offers stale controls after the core stops.
struct ProxiesAvailabilityView: View {
    @Environment(ProxyStore.self) private var store
    @Environment(AppModel.self) private var model
    @State private var startFeedback = 0

    var body: some View {
        Group {
            if store.activeProfile == nil {
                ContentUnavailableView {
                    Label("还没有配置", systemImage: "tray")
                } description: {
                    Text("先导入一个配置。")
                } actions: {
                    Button("导入配置…") { model.showingImport = true }
                        .buttonStyle(.primaryCapsule)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("proxies-import")
                }
            } else {
                ContentUnavailableView {
                    Label {
                        Text(store.isStarting ? String(localized: "内核正在启动…") : String(localized: "内核没有运行"))
                    } icon: {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                    }
                } description: {
                    Text("启动后可以在这里切换节点和测试延迟。")
                } actions: {
                    if store.isStarting {
                        ProgressView().accessibilityLabel("正在启动")
                            .accessibilityIdentifier("proxies-starting")
                    } else {
                        Button("启动") {
                            startFeedback += 1
                            store.start()
                        }
                        .buttonStyle(.secondaryCapsule)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("启动内核")
                        .accessibilityIdentifier("proxies-start")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.groupedBackground)
        .sensoryFeedback(.impact(weight: .medium), trigger: startFeedback)
    }
}
