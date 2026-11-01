import SwiftUI
import VeerProxy

/// First run: add a subscription, choose how to route, turn the proxy on.
struct OnboardingView: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        VStack(spacing: Spacing.xl) {
            StepIndicator(current: store.onboarding ?? .addProfile)
            Group {
                switch store.onboarding ?? .addProfile {
                case .addProfile: AddProfileStep()
                case .routing: RoutingStep()
                case .start: StartStep()
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .floatingPanel()
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface.ignoresSafeArea())
    }
}

private struct StepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.veerAccent : Color.separatorLine)
                    .frame(width: step == current ? 28 : 12, height: 6)
            }
        }
        .animation(Motion.standard, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "第 \(current.rawValue + 1) 步，共 \(OnboardingStep.allCases.count) 步"))
    }
}

private struct StepHeader: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AddProfileStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            StepHeader(title: String(localized: "欢迎使用 Veer"),
                       message: String(localized: "先添加你的订阅。粘贴订阅链接，或者选择一个 Mihomo / Clash 配置文件。订阅链接只保存在这台 Mac 上。"))
            ImportForm()
        }
    }
}

private struct RoutingStep: View {
    @Environment(ProxyStore.self) private var store
    @State private var choice = Choice.keep

    enum Choice { case keep, template }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            StepHeader(title: String(localized: "选择分流方式"),
                       message: String(localized: "分流决定哪些网站走代理、哪些直连。之后随时可以在 Agent 里用一句话调整。"))
            VStack(spacing: Spacing.sm) {
                OptionCard(title: String(localized: "保留订阅自带的规则"),
                           detail: String(localized: "大多数订阅已经配好了常用分流，推荐直接使用。"),
                           selected: choice == .keep) { choice = .keep }
                OptionCard(title: String(localized: "使用内置模板"),
                           detail: String(localized: "用 Veer 的规则模板替换订阅自带的规则：按地区分组，AI 服务优先走美国，国内网站直连。"),
                           selected: choice == .template) { choice = .template }
            }
            HStack {
                Spacer()
                Button("继续") {
                    if let id = store.activeProfileID { store.setTemplate(choice == .template ? RuleTemplate.standard : nil, for: id) }
                    store.onboarding = .start
                }
                .keyboardShortcut(.defaultAction).primaryAction()
            }
        }
    }
}

private struct OptionCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.veerAccent : Color.secondary)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.lg)
            .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous)
                .strokeBorder(selected ? Color.veerAccent.opacity(0.6) : Color.separatorLine))
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct StartStep: View {
    @Environment(ProxyStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            StepHeader(title: String(localized: "开启代理"),
                       message: String(localized: "开启后，Veer 启动内核并设置系统代理，浏览器和大多数 App 会按分流规则上网。"))
            HStack(spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(store.activeProfile?.name ?? "").font(.headline).lineLimit(1).truncationMode(.middle)
                    StatusBadge(kind: store.phase.kind, text: store.phase.title, compact: true)
                }
                Spacer()
                if store.phase == .starting { ProgressView().controlSize(.small) }
                Toggle("开启代理", isOn: Binding(get: { store.isRunning && store.systemProxyOn }, set: { on in
                    if on {
                        store.startWithSystemProxy()
                    } else {
                        // Off here means the proxy too, not only for this run.
                        store.setSystemProxy(false)
                        store.stop()
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
                .disabled(store.phase == .starting)
            }
            .panel()
            // With a way forward: another proxy app holding the port is likely at this point. The
            // notice is why the switch went back off when the core did start.
            if case .failed(let message, let log) = store.phase {
                // Short, as this step has no scroll of its own for the smallest window.
                FailurePanel(message: message, log: log, logHeight: 72, retryIsDefault: true)
            }
            if let notice = store.notice { StatusBadge(kind: .warning, text: notice).fixedSize(horizontal: false, vertical: true) }
            Text("可以随时在菜单栏关闭。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("返回") { store.onboarding = .routing }.neutralControl()
                Spacer()
                // Done is still there after a failure, but trying again is what comes next.
                if case .failed = store.phase {
                    Button("完成") { store.onboarding = nil }.neutralControl()
                } else {
                    Button("完成") { store.onboarding = nil }.keyboardShortcut(.defaultAction).primaryAction()
                }
            }
        }
    }
}
