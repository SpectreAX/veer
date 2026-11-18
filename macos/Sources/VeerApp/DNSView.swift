import AppKit
import SwiftUI
import VeerCore
import VeerProxy
import VeerUI

/// Where a DNS query is sent. The three kinds answer different questions and are never mixed:
/// the core's DNS shows what the rules and nodes see (fake-ip included), the system resolver what
/// macOS itself would get, and a server what that one server says when asked directly.
enum DNSResolverChoice: Hashable {
    case core
    case system
    case server(DNSEndpoint)
    case custom

    /// Servers people ask for a second opinion: one per transport the tool speaks.
    static let presets: [(title: String, endpoint: DNSEndpoint)] = [
        (String(localized: "阿里 DoH"), "https://dns.alidns.com/dns-query"), (String(localized: "腾讯 DNSPod DoH"), "https://doh.pub/dns-query"),
        ("Cloudflare DoH", "https://cloudflare-dns.com/dns-query"), ("Google DoH", "https://dns.google/dns-query"),
        ("Cloudflare DoT", "tls://1.1.1.1"), ("Google DoT", "tls://dns.google"),
        (String(localized: "阿里 223.5.5.5 (UDP)"), "223.5.5.5"), ("Google 8.8.8.8 (TCP)", "tcp://8.8.8.8"),
    ].compactMap { title, address in DNSEndpoint(address).map { (title, $0) } }
}

/// One record as the page shows it. The system resolver gives no TTL.
struct DNSShownRecord: Identifiable, Hashable {
    let id: String
    let type: String
    let data: String
    let name: String
    let ttl: Int?

    var address: IPAddr? { type == "A" || type == "AAAA" ? IPAddr(data) : nil }
}

/// What one query returned, from whichever resolver. Fields a resolver does not give are nil, and
/// the page says so instead of inventing them.
struct DNSOutcome: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let type: DNSRecordKind
    /// The server asked, or the resolver's name.
    let server: String
    /// UDP, TCP, DoT or DoH; nil where the resolver hides it.
    let transport: String?
    let duration: TimeInterval
    let status: String
    let answers: [DNSShownRecord]
    let authority: [DNSShownRecord]
    let additional: [DNSShownRecord]
    /// The header's flags; nil without a DNS message.
    let flags: [String]?
    let raw: String?
    let askedDNSSEC: Bool

    var succeeded: Bool { status == "NOERROR" }
    var hasFakeIP: Bool { answers.contains { $0.address?.isFakeIP == true } }

    /// Everything, as plain text.
    var text: String {
        var lines = ["\(name) \(type.rawValue) @\(server)" + (transport.map { " (\($0))" } ?? ""),
                     "\(status) · \(Int(duration * 1000)) ms" + (flags.map { " · flags: \($0.joined(separator: " "))" } ?? "")]
        for (title, rows) in [("ANSWER", answers), ("AUTHORITY", authority), ("ADDITIONAL", additional)] where !rows.isEmpty {
            lines.append(";; \(title)")
            lines += rows.map { "\($0.name)\t\($0.ttl.map(String.init) ?? "-")\t\($0.type)\t\($0.data)" }
        }
        return lines.joined(separator: "\n")
    }

    init(_ exchange: DNSExchange, askedDNSSEC: Bool) {
        func rows(_ section: DNSRecordRow.Section) -> [DNSShownRecord] {
            exchange.response.records(in: section).map { DNSShownRecord(id: $0.id, type: $0.type, data: $0.data, name: $0.name, ttl: $0.ttl) }
        }
        name = exchange.name
        type = exchange.type
        server = exchange.server
        transport = exchange.transport.rawValue
        duration = exchange.duration
        status = exchange.response.status
        answers = rows(.answer)
        authority = rows(.authority)
        additional = rows(.additional)
        flags = exchange.response.flags
        raw = exchange.response.rawText
        self.askedDNSSEC = askedDNSSEC
    }

    init(name: String, type: DNSRecordKind, server: String, duration: TimeInterval, status: String, answers: [DNSShownRecord]) {
        self.name = name
        self.type = type
        self.server = server
        transport = nil
        self.duration = duration
        self.status = status
        self.answers = answers
        authority = []
        additional = []
        flags = nil
        raw = nil
        askedDNSSEC = false
    }
}

/// Looks a name up three ways: through the core, through macOS, or by asking one server directly
/// over UDP, TCP, TLS or HTTPS. Every result says where it came from and how, and nothing falls
/// back to another resolver. Works with the core stopped, except for the core's own DNS.
struct DNSView: View {
    @Environment(ProxyStore.self) private var store
    @State private var name = ""
    @State private var type = DNSRecordKind.ipv4
    @State private var choice = DNSResolverChoice.core
    @State private var custom = ""
    @State private var dnssec = false
    @State private var outcome: DNSOutcome?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var history: [DNSOutcome] = []
    @State private var showsRaw = false

    private static let domainFieldWidth: CGFloat = 220
    private static let historyLimit = 20
    static let coreStatuses = DNSWire.statuses

    private var asking: Bool { task != nil }

    /// The servers the active config names that can be asked from here.
    private var configured: [(text: String, endpoint: DNSEndpoint)] {
        guard let text = store.effective?.text else { return [] }
        return DNSServer.configured(in: text).compactMap { server in DNSEndpoint(server).map { (server, $0) } }
    }

    private var endpoint: DNSEndpoint? {
        switch choice {
        case .server(let endpoint): endpoint
        case .custom: DNSEndpoint(custom)
        case .core, .system: nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // The field on a line of its own when it would be too short to read a domain in.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.sm) {
                        domainField.frame(minWidth: Self.domainFieldWidth)
                        lookupControls
                    }
                    VStack(alignment: .trailing, spacing: Spacing.sm) {
                        domainField
                        HStack(spacing: Spacing.sm) { lookupControls }
                    }
                }
                resolverControls
                Text(pathNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { StatusBadge(kind: .failure, text: error).fixedSize(horizontal: false, vertical: true) }
                if let outcome { result(outcome) }
                if !history.isEmpty { historyList }
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { if !store.isRunning, choice == .core { choice = .system } }
        .onChange(of: store.isRunning) { _, running in if !running, choice == .core { choice = .system } }
        .onDisappear { task?.cancel() }
    }

    private var domainField: some View {
        TextField("域名或 IP", text: $name, prompt: Text(verbatim: "www.example.com"))
            .textFieldStyle(.roundedBorder)
            .onSubmit(ask)
    }

    @ViewBuilder private var lookupControls: some View {
        Picker("类型", selection: $type) { ForEach(DNSRecordKind.allCases) { Text(verbatim: $0.rawValue).tag($0) } }
            .labelsHidden().fixedSize().neutralControl()
            .help("记录类型")
        if asking {
            Button("取消") { task?.cancel() }.secondaryAction()
        } else {
            Button("查询", action: ask).primaryAction(.regular).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var resolverControls: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.md) {
                    resolverPicker
                    dnssecToggle
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    resolverPicker
                    dnssecToggle
                }
            }
            if choice == .custom {
                TextField("服务器地址", text: $custom, prompt: Text(verbatim: "https://…/dns-query · tls://host · tcp://host · 223.5.5.5"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(ask)
            }
        }
    }

    private var resolverPicker: some View {
        Picker("解析器", selection: $choice) {
            Text("内核 DNS（规则和节点看到的结果）").tag(DNSResolverChoice.core).disabled(!store.isRunning)
            Text("系统 DNS（macOS 自己的解析）").tag(DNSResolverChoice.system)
            Section("直接询问一个服务器") {
                ForEach(DNSResolverChoice.presets, id: \.title) { Text(verbatim: $0.title).tag(DNSResolverChoice.server($0.endpoint)) }
            }
            if !configured.isEmpty {
                Section("当前配置里的 DNS") {
                    ForEach(configured, id: \.text) { Text(verbatim: $0.text).tag(DNSResolverChoice.server($0.endpoint)) }
                }
            }
            Text("自定义服务器…").tag(DNSResolverChoice.custom)
        }
        // Its title is the first thing in it, and it narrows with the page instead of running past its edge.
        .labelsHidden()
        .frame(maxWidth: 340, alignment: .leading)
        .neutralControl()
    }

    private var dnssecToggle: some View {
        Toggle("请求 DNSSEC 记录", isOn: $dnssec)
            .toggleStyle(.checkbox)
            .disabled(endpoint == nil && choice != .custom)
            .help("在查询里带上 DO 标志，请服务器一并返回签名。Veer 不验证签名；结果里的 AD 标志只表示服务器自称验证过。")
    }

    /// Where this query goes, so that asking a server directly is never mistaken for going through the proxy.
    private var pathNote: String {
        switch choice {
        case .core:
            String(localized: "由内核按当前 DNS 设置解析，结果和规则、节点看到的一致。fake-ip 模式下会得到 198.18 开头的虚拟地址，不是网站的真实地址。")
        case .system:
            String(localized: "由 macOS 的解析器解析，只返回 A 和 AAAA 地址，没有 TTL。Veer 接管了系统 DNS（TUN 模式）时，这里得到的也是内核的结果。")
        case .server, .custom:
            String(localized: "直接从这台 Mac 发给所选服务器，不走系统代理和分流规则，也不会改用别的服务器。只有开启 TUN 模式时，这个请求才会和其他流量一样经过内核。")
        }
    }

    // MARK: Result

    @ViewBuilder private func result(_ outcome: DNSOutcome) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.sm) {
                    summary(outcome)
                    Spacer(minLength: Spacing.sm)
                    copyAll(outcome)
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    summary(outcome)
                    copyAll(outcome)
                }
            }
            if outcome.hasFakeIP {
                // A server asked over plain DNS can still be answered by the core, which takes over port 53.
                let direct = outcome.transport != nil
                StatusBadge(kind: .warning, text: direct
                    ? String(localized: "结果是 198.18 开头的 fake-ip：这个明文 DNS 请求被内核接管了，回答的不是所选服务器。要看真实地址，请改用 DoH 或 DoT 服务器。")
                    : String(localized: "结果是 198.18 开头的 fake-ip：这个请求被内核接管了，不是网站的真实地址。要看真实地址，请直接询问一个服务器。"),
                    compact: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let flags = outcome.flags {
                Text(verbatim: String(localized: "标志：\(flags.joined(separator: " "))") + "  ·  " + dnssecNote(outcome, flags: flags))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("这个解析器不提供 DNS 报文：没有标志、权威和附加记录，也没有原始响应。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            section(String(localized: "回答"), outcome.answers)
            section(String(localized: "权威"), outcome.authority)
            section(String(localized: "附加"), outcome.additional)
            if let raw = outcome.raw {
                DisclosureGroup(String(localized: "原始响应"), isExpanded: $showsRaw) {
                    Text(verbatim: raw).font(Typography.codeSmall).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Spacing.xs)
                }
                .font(.callout)
            }
        }
        .panel()
    }

    private func summary(_ outcome: DNSOutcome) -> some View {
        HStack(spacing: Spacing.sm) {
            StatusBadge(kind: outcome.succeeded ? (outcome.answers.isEmpty ? .neutral : .success) : .warning,
                        text: outcome.succeeded && outcome.answers.isEmpty ? String(localized: "没有 \(outcome.type.rawValue) 记录") : outcome.status)
            Text(verbatim: [outcome.server, outcome.transport, "\(Int(outcome.duration * 1000)) ms"].compactMap(\.self).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func copyAll(_ outcome: DNSOutcome) -> some View {
        Button(String(localized: "复制全部")) { Self.copy(outcome.text) }
            .secondaryAction().controlSize(.small)
            .help("复制整个结果")
    }

    /// What was asked about DNSSEC and what the server claimed. Nothing is verified here.
    private func dnssecNote(_ outcome: DNSOutcome, flags: [String]) -> String {
        if flags.contains("ad") { return String(localized: "服务器自称已验证 DNSSEC（AD）；Veer 没有自行验证。") }
        if outcome.askedDNSSEC { return String(localized: "已请求 DNSSEC 记录；服务器没有声明验证过（无 AD）。") }
        return String(localized: "没有请求 DNSSEC。")
    }

    @ViewBuilder private func section(_ title: String, _ rows: [DNSShownRecord]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, Spacing.xs)
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                        Text(verbatim: row.type).font(Typography.codeSmall).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(verbatim: row.data).font(Typography.code).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: row.name + (row.ttl.map { " · TTL \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Spacing.xs)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button(String(localized: "复制记录值")) { Self.copy(row.data) }
                        Button(String(localized: "复制整条记录")) { Self.copy("\(row.name)\t\(row.ttl.map(String.init) ?? "-")\t\(row.type)\t\(row.data)") }
                    }
                    Divider()
                }
            }
        }
    }

    // MARK: History

    private var historyList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("最近的查询").font(.headline)
                Spacer()
                Button(String(localized: "清除")) { history = [] }
                    .buttonStyle(.link).font(.callout)
                    .help("清除查询记录；记录只保存在这次运行里")
            }
            ForEach(history) { past in
                Button { outcome = past; error = nil } label: {
                    HStack(spacing: Spacing.sm) {
                        Text(verbatim: past.type.rawValue).font(Typography.codeSmall).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        Text(verbatim: past.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Spacing.sm)
                        Text(verbatim: "\(past.status) · \(past.server)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, Spacing.xxs)
                .help("再看这次的结果")
            }
        }
        .panel()
    }

    // MARK: Asking

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func ask() {
        let query = name.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !asking else { return }
        if choice == .custom, endpoint == nil {
            error = String(localized: "服务器地址无效：支持 https://…（DoH）、tls://主机（DoT）、tcp://主机、udp://主机或直接写 IP。不支持 DoQ。")
            return
        }
        error = nil
        let type = type, choice = choice, endpoint = endpoint, dnssec = dnssec
        task = Task {
            defer { task = nil }
            do {
                let found = try await Self.run(Request(query: query, type: type, choice: choice, endpoint: endpoint, dnssec: dnssec), store: store)
                outcome = found
                history.removeAll { $0.name == found.name && $0.type == found.type && $0.server == found.server }
                history.insert(found, at: 0)
                if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
            } catch is CancellationError {
                error = nil
            } catch {
                outcome = nil
                self.error = (error as? EditorError)?.message ?? store.message(for: error)
            }
        }
    }

    private struct Request {
        let query: String
        let type: DNSRecordKind
        let choice: DNSResolverChoice
        let endpoint: DNSEndpoint?
        let dnssec: Bool
    }

    private static func run(_ request: Request, store: ProxyStore) async throws -> DNSOutcome {
        let query = request.query, type = request.type, dnssec = request.dnssec
        let started = Date()
        switch request.choice {
        case .core:
            let name = try DNSWire.queryName(query, type: type)
            let result = try await store.lookUp(name, type: type.rawValue)
            let rows = result.answers.enumerated().map { index, answer in
                DNSShownRecord(id: "core-\(index)", type: answer.typeName, data: answer.data, name: answer.name, ttl: answer.ttl)
            }
            let status = result.status < coreStatuses.count ? coreStatuses[result.status] : "RCODE \(result.status)"
            return DNSOutcome(name: name, type: type, server: String(localized: "内核 DNS"), duration: Date().timeIntervalSince(started),
                              status: status, answers: rows)
        case .system:
            let found = try await DNSClient.system(query, type: type)
            let rows = found.addresses.enumerated().map { index, address in
                DNSShownRecord(id: "system-\(index)", type: type.rawValue, data: address, name: found.name, ttl: nil)
            }
            return DNSOutcome(name: found.name, type: type, server: String(localized: "系统 DNS"), duration: Date().timeIntervalSince(started),
                              status: found.status, answers: rows)
        case .server, .custom:
            guard let endpoint = request.endpoint else { throw EditorError(String(localized: "服务器地址无效。")) }
            return DNSOutcome(try await DNSClient().query(query, type: type, endpoint: endpoint, dnssec: dnssec), askedDNSSEC: dnssec)
        }
    }
}
