import SwiftUI
import VeerCore

struct AgentConversationsSheet: View {
    @Environment(AgentStore.self) private var agent
    @Environment(ProxyStore.self) private var proxy
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var deletion: Session?

    var body: some View {
        NavigationStack {
            List {
                ForEach(agent.sessions.sorted { $0.updatedAt > $1.updatedAt }) { session in
                    Button {
                        agent.select(session.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.s) {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(session.turns.first(where: { !$0.isNote })?.prompt ?? session.title)
                                    .font(.body).foregroundStyle(.primary)
                                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                if typeSize.isAccessibilitySize {
                                    Text(relativeDate(session)).font(.footnote).foregroundStyle(.secondary)
                                    Text(profileName(session)).font(.footnote).foregroundStyle(.secondary)
                                } else {
                                    Text("\(relativeDate(session)) · \(profileName(session))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if session.id == agent.selectedID {
                                Image(systemName: "checkmark").foregroundStyle(Color.veerAccent)
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityAddTraits(session.id == agent.selectedID ? .isSelected : [])
                    .accessibilityIdentifier("agent-conversation-\(session.id.uuidString)")
                    .swipeActions(allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { deletion = session }
                            .accessibilityIdentifier("agent-conversation-delete")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if agent.sessions.isEmpty {
                    ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                        .tint(.accentFill).accessibilityLabel("完成")
                        .accessibilityIdentifier("conversations-done")
                }
            }
            .alert("删除对话？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
                Button("删除", role: .destructive) {
                    if let deletion { agent.delete(deletion) }
                    deletion = nil
                }
                Button("取消", role: .cancel) { deletion = nil }
            } message: {
                Text("对话记录会从本机删除；已经应用的修改仍在“我的分流”里。")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func relativeDate(_ session: Session) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: session.updatedAt, relativeTo: .now)
    }

    private func profileName(_ session: Session) -> String {
        session.profileID.flatMap { id in proxy.profiles.first { $0.id == id }?.name } ?? String(localized: "已删除的配置")
    }
}
