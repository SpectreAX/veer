import AppKit
import SwiftUI
import VeerUI

/// The one place subscription work reports, at the foot of the window: a spinner while it runs,
/// a check that leaves on its own, or the reason with Retry and Close. The same glass capsule as the
/// Agent's toast, so the window has one kind of transient message.
struct ActivityToast: View {
    let activity: Activity
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            symbol
            message
                .font(.callout)
                .help(activity.message)
                // The tooltip is for the pointer; VoiceOver already reads the same text as the label.
                .accessibilityHint(Text(verbatim: ""))
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if activity.isFailure {
                Button(String(localized: "重试"), action: retry).buttonStyle(.borderless).foregroundStyle(Color.accentOnGlass)
                // Primary, as the reason: secondary (either form) on the glass measured 2.5:1 in light,
                // below the 3:1 a control's glyph needs.
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)
                    // Not just "Close": in Manage Profiles the sheet's own Close is beside it, and two buttons
                    // of one name left VoiceOver users to guess which closes what.
                    .help(String(localized: "关闭提示"))
                    .accessibilityLabel(String(localized: "关闭提示"))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + Spacing.xxs)
        .glassSurface(in: Capsule())
        .accessibilityElement(children: .contain)
        .onAppear { announce() }
        .onChange(of: activity) { announce() }
    }

    @ViewBuilder private var message: some View {
        if case .failed(let reason) = activity.kind {
            // The reason is in the primary colour: secondary on the capsule's glass measured 2.5:1 (light)
            // and 3.3:1 (dark), below 4.5:1 for text this small. The title's weight keeps the two apart.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(String(localized: "“\(activity.name)”更新失败")).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text(reason).foregroundStyle(.primary).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(activity.message).lineLimit(2).truncationMode(.middle)
        }
    }

    @ViewBuilder private var symbol: some View {
        switch activity.kind {
        case .updating: ProgressView().controlSize(.small).accessibilityHidden(true)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusKind.warning.color).accessibilityHidden(true)
        default: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.veerAccent).accessibilityHidden(true)
        }
    }

    private func announce() {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: activity.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
