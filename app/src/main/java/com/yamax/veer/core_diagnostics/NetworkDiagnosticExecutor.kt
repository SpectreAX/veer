package com.yamax.veer.core_diagnostics

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.data.ConfigManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.InetSocketAddress
import java.net.Proxy
import java.util.concurrent.TimeUnit
import kotlin.system.measureTimeMillis

internal enum class DiagnosticCategory {
    HEALTHY,
    SYSTEM_NETWORK,
    VPN_TUN,
    CONTROLLER,
    DNS,
    RULE,
    PROXY_EXIT,
    TARGET_SITE,
}

internal enum class DiagnosticCheckStatus { PASS, FAIL, SKIPPED }

internal data class DiagnosticCheck(
    val id: String,
    val label: String,
    val status: DiagnosticCheckStatus,
    val detail: String,
)

internal data class DiagnosticReport(
    val category: DiagnosticCategory,
    val target: String,
    val checks: List<DiagnosticCheck>,
    val matchedRule: MihomoRepository.RuleState?,
    val summary: String,
)

internal data class DiagnosticEvidence(
    val physicalNetwork: Boolean,
    val vpnRunning: Boolean,
    val tunPresent: Boolean,
    val controllerReachable: Boolean,
    val dnsHealthy: Boolean,
    val ruleBlocked: Boolean,
    val proxyInternetHealthy: Boolean,
    val targetReachable: Boolean,
)

internal object NetworkDiagnosisClassifier {
    fun classify(evidence: DiagnosticEvidence): DiagnosticCategory = when {
        !evidence.physicalNetwork -> DiagnosticCategory.SYSTEM_NETWORK
        !evidence.vpnRunning || !evidence.tunPresent -> DiagnosticCategory.VPN_TUN
        !evidence.controllerReachable -> DiagnosticCategory.CONTROLLER
        !evidence.dnsHealthy -> DiagnosticCategory.DNS
        evidence.ruleBlocked -> DiagnosticCategory.RULE
        !evidence.proxyInternetHealthy -> DiagnosticCategory.PROXY_EXIT
        !evidence.targetReachable -> DiagnosticCategory.TARGET_SITE
        else -> DiagnosticCategory.HEALTHY
    }
}

/**
 * Layered diagnosis of the real Mihomo path. Requests explicitly use the local
 * mixed port because Veer itself is excluded from its Android VPN TUN.
 */
internal class NetworkDiagnosticExecutor(
    context: Context,
    private val mihomo: MihomoRepository = MihomoRepository.get(),
    private val proxyClient: OkHttpClient = defaultProxyClient(),
    private val probeOutcomeForTesting: (String) -> Boolean? = { null },
) {
    private val appContext = context.applicationContext

    suspend fun diagnose(rawTarget: String): DiagnosticReport = withContext(Dispatchers.IO) {
        val target = normalizeTarget(rawTarget)
        val connectivity = networkState(appContext)
        val vpnRunning = MihomoEngine.state.value is EngineState.Running
        val controllerReachable = mihomo.version() != null

        val dns = if (controllerReachable) {
            mihomo.dnsQuery(target.domain)
        } else {
            MihomoRepository.DnsQueryResult(false, emptyList(), "controller unavailable")
        }
        val rules = if (controllerReachable) mihomo.rulesSnapshot() else emptyList()
        val matchedRule = matchingRule(rules, target.domain, target.service)
        val ruleBlocked = matchedRule?.proxy?.uppercase()?.startsWith("REJECT") == true
        val routing = if (controllerReachable) mihomo.routingSnapshot()
        else MihomoRepository.RoutingSnapshot.EMPTY
        val policy = matchedRule?.proxy
            ?.takeIf(String::isNotBlank)
            ?: ConfigManager.runtimeDefaultPolicy(appContext)
        val leaf = policy?.let(routing::resolvedLeaf)
        val direct = policy == "DIRECT" || leaf?.type.equals("Direct", ignoreCase = true)
        val nodeDelay = if (
            controllerReachable && !ruleBlocked && !direct && leaf != null
        ) {
            mihomo.probeProxyDelay(leaf.name, timeoutMs = 3_000)
        } else {
            null
        }

        val internetProbe = if (
            connectivity.physical && vpnRunning && connectivity.tun &&
            controllerReachable && !ruleBlocked
        ) {
            probe(INTERNET_PROBE_URL, requireSuccessfulStatus = true)
        } else {
            ProbeResult(false, null, null, "prerequisite unavailable")
        }
        val targetProbe = if (
            dns.success && internetProbe.success && !ruleBlocked
        ) {
            probe(target.url, requireSuccessfulStatus = false)
        } else {
            ProbeResult(false, null, null, "prerequisite unavailable")
        }
        val proxyInternetHealthy = internetProbe.success

        val evidence = DiagnosticEvidence(
            physicalNetwork = connectivity.physical,
            vpnRunning = vpnRunning,
            tunPresent = connectivity.tun,
            controllerReachable = controllerReachable,
            dnsHealthy = dns.success,
            ruleBlocked = ruleBlocked,
            proxyInternetHealthy = proxyInternetHealthy,
            targetReachable = targetProbe.success,
        )
        val category = NetworkDiagnosisClassifier.classify(evidence)
        val vpnPrerequisite = connectivity.physical
        val controllerPrerequisite = connectivity.physical && vpnRunning && connectivity.tun
        val controllerReady = controllerPrerequisite && controllerReachable
        val checks = listOf(
            check("physical", "底层网络", connectivity.physical, connectivity.physicalDetail),
            layerCheck(
                id = "tun",
                label = "Android VPN/TUN",
                prerequisite = vpnPrerequisite,
                healthy = vpnRunning && connectivity.tun,
                detail = when {
                    !vpnRunning -> "Veer VPN 未运行"
                    connectivity.tun -> "VPN 网络已建立"
                    else -> "引擎运行但系统中没有 VPN 网络"
                },
                skippedDetail = "底层网络不可用，跳过 VPN/TUN 检查",
            ),
            layerCheck(
                id = "controller",
                label = "Mihomo 控制器",
                prerequisite = controllerPrerequisite,
                healthy = controllerReachable,
                detail = if (controllerReachable) "127.0.0.1:9090 可用" else "控制器不可达",
                skippedDetail = "VPN/TUN 不可用，跳过控制器检查",
            ),
            layerCheck(
                id = "dns",
                label = "Mihomo DNS",
                prerequisite = controllerReady,
                healthy = dns.success,
                detail = if (dns.success) {
                    "${target.domain} → ${dns.addresses.take(3).joinToString()}"
                } else {
                    "${target.domain} 解析失败：${dns.message}"
                },
                skippedDetail = "控制器不可用，跳过 DNS 检查",
            ),
            DiagnosticCheck(
                id = "rule",
                label = "规则匹配",
                status = if (!controllerReady) DiagnosticCheckStatus.SKIPPED
                else if (ruleBlocked) DiagnosticCheckStatus.FAIL
                else if (matchedRule != null) DiagnosticCheckStatus.PASS
                else DiagnosticCheckStatus.SKIPPED,
                detail = if (!controllerReady) {
                    "控制器不可用，跳过规则匹配"
                } else matchedRule?.let {
                    "#${it.index} ${it.type}(${it.payload}) → ${it.proxy}"
                } ?: "控制器未返回可本地判定的匹配规则",
            ),
            DiagnosticCheck(
                id = "node",
                label = "代理节点",
                status = when {
                    !controllerReady || !dns.success || ruleBlocked ->
                        DiagnosticCheckStatus.SKIPPED
                    direct -> DiagnosticCheckStatus.SKIPPED
                    leaf == null -> DiagnosticCheckStatus.FAIL
                    nodeDelay != null || internetProbe.success -> DiagnosticCheckStatus.PASS
                    else -> DiagnosticCheckStatus.FAIL
                },
                detail = when {
                    !controllerReady -> "控制器不可用，跳过节点探测"
                    !dns.success -> "DNS 失败，跳过节点探测"
                    ruleBlocked -> "目标已被规则阻断，跳过节点探测"
                    direct -> "当前规则为 DIRECT"
                    leaf == null -> "无法解析策略 ${policy ?: "未知"} 的叶子节点"
                    nodeDelay != null -> "${leaf.name} · ${nodeDelay}ms"
                    internetProbe.success -> "${leaf.name} · 延迟接口无结果，但实际出口可用"
                    else -> "${leaf.name} · 延迟和实际出口探测均失败"
                },
            ),
            DiagnosticCheck(
                id = "internet",
                label = "机场出口",
                status = if (!controllerReady || ruleBlocked) DiagnosticCheckStatus.SKIPPED
                else if (internetProbe.success) DiagnosticCheckStatus.PASS
                else DiagnosticCheckStatus.FAIL,
                detail = if (!controllerReady) "控制器不可用，跳过出口探测"
                else if (ruleBlocked) "目标已被规则阻断，跳过出口探测"
                else internetProbe.detail("代理出口"),
            ),
            DiagnosticCheck(
                id = "target",
                label = "目标站点",
                status = when {
                    ruleBlocked || !dns.success || !internetProbe.success ->
                        DiagnosticCheckStatus.SKIPPED
                    targetProbe.success -> DiagnosticCheckStatus.PASS
                    else -> DiagnosticCheckStatus.FAIL
                },
                detail = when {
                    ruleBlocked -> "目标已被规则阻断"
                    !dns.success -> "DNS 失败，跳过目标探测"
                    !internetProbe.success -> "代理出口失败，跳过目标探测"
                    else -> targetProbe.detail(target.domain)
                },
            ),
        )
        DiagnosticReport(
            category = category,
            target = target.domain,
            checks = checks,
            matchedRule = matchedRule,
            summary = summary(category, target.domain, matchedRule, leaf?.name),
        )
    }

    private fun probe(url: String, requireSuccessfulStatus: Boolean): ProbeResult {
        probeOutcomeForTesting(url)?.let { forcedSuccess ->
            return ProbeResult(
                success = forcedSuccess,
                status = if (forcedSuccess) 204 else null,
                latencyMs = if (forcedSuccess) 1 else null,
                error = if (forcedSuccess) null else "injected diagnostic probe failure",
            )
        }
        var responseCode: Int? = null
        var error: String? = null
        var success = false
        val elapsed = measureTimeMillis {
            success = runCatching {
                proxyClient.connectionPool.evictAll()
                proxyClient.newCall(
                    Request.Builder()
                        .url(url)
                        .header("Cache-Control", "no-cache")
                        .header("Connection", "close")
                        .get()
                        .build(),
                ).execute().use { response ->
                    responseCode = response.code
                    if (requireSuccessfulStatus) response.isSuccessful else true
                }
            }.onFailure { error = it.message ?: it.javaClass.simpleName }
                .getOrDefault(false)
        }
        return ProbeResult(success, responseCode, elapsed.takeIf { success }, error)
    }

    private data class ProbeResult(
        val success: Boolean,
        val status: Int?,
        val latencyMs: Long?,
        val error: String?,
    ) {
        fun detail(label: String): String = when {
            success -> "$label 可达 · HTTP ${status ?: "?"} · ${latencyMs ?: 0}ms"
            error != null -> "$label 失败 · $error"
            else -> "$label 未执行或无有效响应"
        }
    }

    private data class Target(
        val service: String?,
        val domain: String,
        val url: String,
    )

    private data class NetworkState(
        val physical: Boolean,
        val tun: Boolean,
        val physicalDetail: String,
    )

    companion object {
        private const val INTERNET_PROBE_URL = "https://www.gstatic.com/generate_204"
        private const val MIHOMO_MIXED_PORT = 7890

        internal fun matchingRule(
            rules: List<MihomoRepository.RuleState>,
            domain: String,
            service: String?,
        ): MihomoRepository.RuleState? = rules.sortedBy { it.index }.firstOrNull { rule ->
            val payload = rule.payload.trim().trimStart('.')
            when (rule.type.lowercase()) {
                "domain" -> domain.equals(payload, ignoreCase = true)
                "domainsuffix" -> domain.equals(payload, ignoreCase = true) ||
                    domain.endsWith(".$payload", ignoreCase = true)
                "domainkeyword" -> domain.contains(payload, ignoreCase = true)
                "geosite" -> service != null && service.equals(payload, ignoreCase = true)
                "match" -> true
                else -> false
            }
        }

        private fun normalizeTarget(raw: String): Target {
            val normalized = raw.trim().lowercase()
            return when (normalized) {
                "chatgpt", "openai" -> Target("openai", "chatgpt.com", "https://chatgpt.com/")
                "netflix", "网飞", "奈飞" ->
                    Target("netflix", "www.netflix.com", "https://www.netflix.com/")
                "youtube", "油管" ->
                    Target("youtube", "www.youtube.com", "https://www.youtube.com/generate_204")
                "google", "谷歌" ->
                    Target("google", "www.google.com", "https://www.google.com/generate_204")
                "github" -> Target("github", "github.com", "https://github.com/")
                else -> {
                    val domain = DOMAIN_REGEX.find(normalized)?.value ?: "www.gstatic.com"
                    Target(null, domain, "https://$domain/")
                }
            }
        }

        private fun networkState(context: Context): NetworkState {
            val manager = context.getSystemService(ConnectivityManager::class.java)
            var physical = false
            var tun = false
            val transports = mutableSetOf<String>()
            manager.allNetworks.forEach { network ->
                val capabilities = manager.getNetworkCapabilities(network) ?: return@forEach
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    tun = true
                } else if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                    physical = true
                    if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                        transports += "Wi-Fi"
                    }
                    if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                        transports += "移动网络"
                    }
                    if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
                        transports += "以太网"
                    }
                }
            }
            return NetworkState(
                physical = physical,
                tun = tun,
                physicalDetail = if (physical) {
                    "${transports.ifEmpty { setOf("物理网络") }.joinToString()} 可用"
                } else {
                    "没有可用的非 VPN 网络"
                },
            )
        }

        private fun check(
            id: String,
            label: String,
            healthy: Boolean,
            detail: String,
        ) = DiagnosticCheck(
            id = id,
            label = label,
            status = if (healthy) DiagnosticCheckStatus.PASS else DiagnosticCheckStatus.FAIL,
            detail = detail,
        )

        private fun layerCheck(
            id: String,
            label: String,
            prerequisite: Boolean,
            healthy: Boolean,
            detail: String,
            skippedDetail: String,
        ) = DiagnosticCheck(
            id = id,
            label = label,
            status = when {
                !prerequisite -> DiagnosticCheckStatus.SKIPPED
                healthy -> DiagnosticCheckStatus.PASS
                else -> DiagnosticCheckStatus.FAIL
            },
            detail = if (prerequisite) detail else skippedDetail,
        )

        private fun summary(
            category: DiagnosticCategory,
            domain: String,
            rule: MihomoRepository.RuleState?,
            node: String?,
        ): String = when (category) {
            DiagnosticCategory.HEALTHY ->
                "诊断完成：$domain 可访问，DNS、规则和代理出口均正常。"
            DiagnosticCategory.SYSTEM_NETWORK ->
                "诊断结果：系统底层网络不可用，请先检查 Wi-Fi 或移动网络。"
            DiagnosticCategory.VPN_TUN ->
                "诊断结果：Veer VPN/TUN 未正常建立。"
            DiagnosticCategory.CONTROLLER ->
                "诊断结果：Mihomo 控制器不可达，内核可能未正常运行。"
            DiagnosticCategory.DNS ->
                "诊断结果：Mihomo 无法解析 $domain，故障位于 DNS。"
            DiagnosticCategory.RULE ->
                "诊断结果：规则 #${rule?.index ?: "?"} 将 $domain 路由至 " +
                    "${rule?.proxy ?: "REJECT"}，请求被规则阻断。"
            DiagnosticCategory.PROXY_EXIT ->
                "诊断结果：节点 ${node ?: "未知"} 或机场出口无法访问互联网。"
            DiagnosticCategory.TARGET_SITE ->
                "诊断结果：代理出口正常，但目标站点 $domain 无法访问。"
        }

        private fun defaultProxyClient(): OkHttpClient = OkHttpClient.Builder()
            .proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", MIHOMO_MIXED_PORT)))
            .connectTimeout(4, TimeUnit.SECONDS)
            .readTimeout(6, TimeUnit.SECONDS)
            .callTimeout(8, TimeUnit.SECONDS)
            .build()

        private val DOMAIN_REGEX = Regex(
            """(?i)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}""",
        )
    }
}
