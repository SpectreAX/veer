package com.yamax.veer.core_ai

import com.yamax.veer.core_mihomo.MihomoRepository

/**
 * Conservative parser for commands whose meaning is deterministic. Returning
 * null is intentional: ambiguous language remains the LLM's responsibility.
 */
internal object LocalPlanResolver {

    internal fun requestedRegionCodes(text: String): Set<String> =
        REGIONS.entries
            .filter { (_, patterns) -> patterns.any { it.containsMatchIn(text) } }
            .mapTo(linkedSetOf()) { it.key }

    /**
     * Regions that are part of a concrete routing request. Keeping this
     * separate from [requestedRegionCodes] prevents diagnostic questions such
     * as "为什么日本节点打不开" from being rejected before diagnosis runs.
     */
    internal fun requestedRoutingRegionCodes(text: String): Set<String> {
        val hasRouteTarget = DOMAIN_REGEX.containsMatchIn(text) ||
            SERVICE_ALIASES.keys.any { text.contains(it, ignoreCase = true) }
        val hasRoutingVerb = ROUTING_PHRASES.any { it.containsMatchIn(text) }
        return if (hasRouteTarget && hasRoutingVerb) requestedRegionCodes(text) else emptySet()
    }

    internal fun regionLabel(code: String): String = REGION_LABELS[code] ?: code

    fun resolve(
        userText: String,
        snapshot: MihomoRepository.RoutingSnapshot,
        preferredSelector: String? = null,
    ): AiPlan? {
        val text = userText.trim()
        if (text.isEmpty()) return null

        resolveDiagnosis(text)?.let { return it }
        resolveDirectOrReject(text)?.let { return it }
        resolveLowestLatency(text, snapshot, preferredSelector)?.let { return it }
        return resolveRegionalRouting(text, snapshot)
    }

    private fun resolveDiagnosis(text: String): AiPlan? {
        if (!DIAGNOSIS_PHRASES.any { it.containsMatchIn(text) }) return null
        val services = servicesIn(text)
        val domains = domainsIn(text)
        if (services.size + domains.size > 1) return null
        val target = services.singleOrNull() ?: domains.singleOrNull() ?: "network"
        return AiPlan.single(
            AiIntent(
                action = AiIntent.Action.DIAGNOSE,
                target = target,
                matchType = AiIntent.MatchType.NONE,
                proxyGroup = "NONE",
                selectionMode = AiIntent.SelectionMode.NONE,
                replyMessage = "正在诊断 $target 的连接状态。",
            ),
        )
    }

    private fun resolveDirectOrReject(text: String): AiPlan? {
        val direct = DIRECT_PHRASES.any { it.containsMatchIn(text) }
        val reject = REJECT_PHRASES.any { it.containsMatchIn(text) }
        if (direct == reject) return null
        val domains = domainsIn(text)
        val services = servicesIn(text)
        if (domains.isEmpty() && services.isEmpty()) return null
        val policy = if (direct) "DIRECT" else "REJECT"
        val verb = if (direct) "直连" else "拦截"
        val domainOperations = domains.map { domain ->
            AiIntent(
                action = AiIntent.Action.ADD_RULE,
                target = domain,
                matchType = AiIntent.MatchType.DOMAIN_SUFFIX,
                proxyGroup = policy,
                selectionMode = AiIntent.SelectionMode.NONE,
                replyMessage = "已将 $domain 设为$verb。",
            )
        }
        val serviceOperations = services.map { service ->
            AiIntent(
                action = AiIntent.Action.ADD_RULE,
                target = service,
                matchType = AiIntent.MatchType.GEOSITE,
                proxyGroup = policy,
                selectionMode = AiIntent.SelectionMode.NONE,
                replyMessage = "已将 $service 设为$verb。",
            )
        }
        val operations = (domainOperations + serviceOperations).take(AiPlan.MAX_OPERATIONS)
        return AiPlan(
            schemaVersion = AiPlan.CURRENT_SCHEMA_VERSION,
            operations = operations,
            replyMessage = "已完成 ${operations.size} 项${verb}规则。",
        )
    }

    private fun resolveLowestLatency(
        text: String,
        snapshot: MihomoRepository.RoutingSnapshot,
        preferredSelector: String?,
    ): AiPlan? {
        if (DOMAIN_REGEX.containsMatchIn(text)) return null
        if (SERVICE_ALIASES.keys.any { text.contains(it, ignoreCase = true) }) return null
        if (!LOW_LATENCY_PHRASES.any { it.containsMatchIn(text) }) return null
        val selector = preferredSelector
            ?.let(snapshot.proxies::get)
            ?.takeIf { it.type == "Selector" }
            ?: snapshot.selectorGroups.firstOrNull { it.name != "GLOBAL" }
            ?: return null
        val intent = AiIntent(
            action = AiIntent.Action.SWITCH_PROXY,
            target = selector.name,
            matchType = AiIntent.MatchType.NONE,
            proxyGroup = "NONE",
            selectionMode = AiIntent.SelectionMode.LOWEST_LATENCY,
            replyMessage = "正在切换到低延迟节点。",
        )
        return AiPlan.single(intent)
    }

    private fun resolveRegionalRouting(
        text: String,
        snapshot: MihomoRepository.RoutingSnapshot,
    ): AiPlan? {
        if (!ROUTING_PHRASES.any { it.containsMatchIn(text) }) return null

        val clauses = text.split(ROUTING_CLAUSE_SEPARATOR)
            .map(String::trim)
            .filter(String::isNotEmpty)
        val clauseOperations = clauses.mapNotNull { clause ->
            resolveRegionalClause(clause, snapshot)
        }.flatten()
        if (clauseOperations.isNotEmpty() && clauseOperations.size <= AiPlan.MAX_OPERATIONS) {
            val allTargets = servicesIn(text).size + domainsIn(text).size
            if (clauseOperations.size == allTargets) {
                return AiPlan(
                    schemaVersion = AiPlan.CURRENT_SCHEMA_VERSION,
                    operations = clauseOperations,
                    replyMessage = clauseOperations.joinToString(" ") { it.replyMessage },
                )
            }
        }

        return resolveRegionalClause(text, snapshot)
            ?.takeIf { it.isNotEmpty() && it.size <= AiPlan.MAX_OPERATIONS }
            ?.let { operations ->
                AiPlan(
                    schemaVersion = AiPlan.CURRENT_SCHEMA_VERSION,
                    operations = operations,
                    replyMessage = operations.joinToString(" ") { it.replyMessage },
                )
            }
    }

    private fun resolveRegionalClause(
        text: String,
        snapshot: MihomoRepository.RoutingSnapshot,
    ): List<AiIntent>? {
        val region = requestedRegionCodes(text).singleOrNull() ?: return null
        val services = servicesIn(text)
        val domains = domainsIn(text)
        if (services.isEmpty() && domains.isEmpty()) return null

        val node = lowestDelayNode(snapshot, region) ?: return null
        val targets =
            domains.map { it to AiIntent.MatchType.DOMAIN_SUFFIX } +
                services.map { it to AiIntent.MatchType.GEOSITE }
        return targets.map { (target, matchType) ->
            AiIntent(
                action = AiIntent.Action.ADD_RULE,
                target = target,
                matchType = matchType,
                proxyGroup = node.name,
                selectionMode = AiIntent.SelectionMode.NONE,
                replyMessage = "已将 $target 路由至 ${node.name}。",
            )
        }
    }

    private fun lowestDelayNode(
        snapshot: MihomoRepository.RoutingSnapshot,
        region: String,
    ): MihomoRepository.ProxyState? =
        snapshot.proxies.values.asSequence()
            .filter { it.members.isEmpty() }
            .filter { it.regionCode == region }
            .filter { it.alive != false && it.delayMs != UNAVAILABLE_DELAY_MS }
            .minWithOrNull(
                compareBy<MihomoRepository.ProxyState> { it.delayMs ?: Int.MAX_VALUE }
                    .thenBy { it.name },
            )

    private fun servicesIn(text: String): List<String> =
        SERVICE_ALIASES.entries
            // A token inside an explicit domain is part of that domain, not a
            // second GEOSITE target (for example netflix.com).
            .filter { (alias) ->
                DOMAIN_REGEX.replace(text, " ").contains(alias, ignoreCase = true)
            }
            .map { it.value }
            .distinct()

    private fun domainsIn(text: String): List<String> =
        DOMAIN_REGEX.findAll(text)
            .map { it.value.lowercase().trimEnd('.') }
            .distinct()
            .toList()

    private val DOMAIN_REGEX = Regex(
        """(?i)(?<![a-z0-9_.-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?![a-z0-9_.-])""",
    )
    private val DIRECT_PHRASES = listOf(
        Regex("""直连|不走代理|绕过代理"""),
        Regex("""(?i)\bdirect\b"""),
    )
    private val REJECT_PHRASES = listOf(
        Regex("""拦截|屏蔽|阻止|去广告"""),
        Regex("""(?i)\breject\b"""),
    )
    private val LOW_LATENCY_PHRASES = listOf(
        Regex("""节点.{0,5}(太卡|很卡|慢).{0,5}(换|切)"""),
        Regex("""(换|切).{0,5}(快点|更快|最快|低延迟)"""),
        Regex("""(最低延迟|延迟最低).{0,5}(节点|切换|换)"""),
        Regex("""(?i)\b(?:slow|laggy).{0,12}\b(?:switch|change|faster)\b"""),
        Regex("""(?i)\b(?:fastest|lowest[\s-]*latency).{0,12}\b(?:node|proxy|switch)\b"""),
    )
    private val DIAGNOSIS_PHRASES = listOf(
        Regex("""诊断|排查|检查.{0,6}(网络|连接)"""),
        Regex("""打不开|无法访问|连不上|上不了网|网络不通"""),
        Regex("""(?i)\bdiagnos(?:e|is)|\btroubleshoot|\b(?:cannot|can't)\s+(?:open|access|connect)|\bnot\s+working\b"""),
    )
    private val ROUTING_PHRASES = listOf(
        Regex("""走|路由|切换到|使用|节点|[日美港台新澳英韩德法加]区"""),
        Regex("""(?i)\b(?:go|route|use|via|switch(?:\s+to)?)\b"""),
    )
    private val ROUTING_CLAUSE_SEPARATOR = Regex("""[,，;；\n]+""")
    private const val UNAVAILABLE_DELAY_MS = 65535
    private val SERVICE_ALIASES = linkedMapOf(
        "netflix" to "netflix",
        "网飞" to "netflix",
        "奈飞" to "netflix",
        "youtube" to "youtube",
        "油管" to "youtube",
        "disneyplus" to "disney",
        "disney+" to "disney",
        "disney plus" to "disney",
        "迪士尼+" to "disney",
        "迪士尼" to "disney",
        "google" to "google",
        "谷歌" to "google",
        "openai" to "openai",
        "chatgpt" to "openai",
        "github" to "github",
        "spotify" to "spotify",
    )
    private val REGIONS = linkedMapOf(
        "JP" to listOf(Regex("""日本|日区"""), Regex("""(?i)\bJP\b|\bJapan\b""")),
        "US" to listOf(Regex("""美国|美区"""), Regex("""(?i)\bUS\b|\bUSA\b|\bUnited States\b""")),
        "HK" to listOf(Regex("""香港|港区"""), Regex("""(?i)\bHK\b|\bHong Kong\b""")),
        "SG" to listOf(Regex("""新加坡|狮城|新区"""), Regex("""(?i)\bSG\b|\bSingapore\b""")),
        "TW" to listOf(Regex("""台湾|台区"""), Regex("""(?i)\bTW\b|\bTaiwan\b""")),
        "MO" to listOf(Regex("""澳门"""), Regex("""(?i)\bMO\b|\bMacau\b""")),
        "GB" to listOf(Regex("""英国|英区"""), Regex("""(?i)\bUK\b|\bGB\b|\bUnited Kingdom\b|\bBritain\b""")),
        "KR" to listOf(Regex("""韩国|韩区"""), Regex("""(?i)\bKR\b|\bKorea\b""")),
        "DE" to listOf(Regex("""德国|德区"""), Regex("""(?i)\bDE\b|\bGermany\b""")),
        "FR" to listOf(Regex("""法国|法区"""), Regex("""(?i)\bFR\b|\bFrance\b""")),
        "CA" to listOf(Regex("""加拿大|加区"""), Regex("""(?i)\bCA\b|\bCanada\b""")),
        "AU" to listOf(Regex("""澳大利亚|澳洲|澳区"""), Regex("""(?i)\bAU\b|\bAustralia\b""")),
    )
    private val REGION_LABELS = mapOf(
        "JP" to "日本",
        "US" to "美国",
        "HK" to "香港",
        "SG" to "新加坡",
        "TW" to "台湾",
        "MO" to "澳门",
        "GB" to "英国",
        "KR" to "韩国",
        "DE" to "德国",
        "FR" to "法国",
        "CA" to "加拿大",
        "AU" to "澳大利亚",
    )
}
