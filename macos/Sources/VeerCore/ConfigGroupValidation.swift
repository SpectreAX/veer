import Foundation
import Yams

public extension ConfigDocument {
    /// The editor can open empty groups to repair them. Imports and execution reject these
    /// before replacing a saved subscription or launching Mihomo, without choosing an exit.
    static func requireGroupMembers(in text: String) throws {
        let groups = try Yams.compose(yaml: text)?.mapping?["proxy-groups"]?.sequence ?? []
        for group in groups {
            guard let fields = group.mapping, let name = fields["name"]?.string else { continue }
            let members = fields["proxies"]?.sequence ?? []
            let providers = fields["use"]?.sequence ?? []
            let includesAll = ["include-all", "include-all-proxies", "include-all-providers"].contains { fields[$0]?.bool == true }
            if members.isEmpty, providers.isEmpty, !includesAll {
                throw EditorError(String(localized: "策略组“\(name)”没有节点或 Provider，无法启动。请更新订阅或换用有效配置；本地配置可在“编辑成员”中修复。"))
            }
        }
    }
}
