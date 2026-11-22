import Foundation

/// When a question to the user is for something Veer or the model could find out itself.
/// The model asked "which domains?" for requests such as "Google through the US, the parts that
/// work directly go direct": the domains are in MetaCubeX's lists (`google-cn`), in a search, or in
/// what the model knows. Only choices (an exit, a preference between ways of doing it) are the
/// user's to make; a question that offers such choices as options is left alone.
public enum ClarificationPolicy {
    static let factPatterns = [
        #"(哪些|哪几个|哪个|具体|提供|列出|告诉我|给出|说明).{0,10}(域名|网址|网站地址|子域名|地址|域)"#,
        #"(域名|网址).{0,6}(是什么|有哪些|清单|列表)"#,
        #"(which|what|list|provide|tell me|specify).{0,30}(domains?|urls?|hostnames?|sites)"#,
    ]

    /// A question asking for facts. One that asks where traffic should go, or offers options
    /// (ready-made choices), is a real question.
    public static func asksForFacts(_ question: String, options: [ClarifyOption]) -> Bool {
        guard options.isEmpty else { return false }
        let lower = question.lowercased()
        return factPatterns.contains { lower.matches($0) }
    }

    /// Sent back to the model in place of the user's answer.
    static func lookFurtherMessage(search: Bool) -> String {
        let how = search ? "先请求联网搜索（输出格式中的 search），或者" : ""
        return """
        你在问用户可以查到的事实（域名或某服务包含哪些域名）。不要让用户提供：\(how)根据“本机查询结果”里服务的规则集\
        （包括中国大陆可直连的部分，例如 xxx-cn、xxx@cn）、已确认的规则集名称，或你确定的主要域名直接输出修改计划，\
        在 understanding 里写明哪些部分未经验证。只有出口或偏好确实无法判断时才澄清，并在 options 里给出可直接执行的方案。只输出一个 JSON 对象。
        """  // for the AI
    }
}
