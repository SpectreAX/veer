package com.yamax.veer.core_profile.internal.generator

import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_profile.DnsEnhancedMode
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import com.yamax.veer.core_profile.DnsOverrideValidator
import com.yamax.veer.core_profile.ImportedProfile
import com.yamax.veer.core_profile.NormalizedDns
import com.yamax.veer.core_profile.NormalizedProxy
import com.yamax.veer.core_profile.NormalizedProxyGroup
import com.yamax.veer.core_profile.internal.parser.toSnakeYamlAny
import org.yaml.snakeyaml.DumperOptions
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.security.MessageDigest

/**
 * Produces a safe Mihomo-compatible runtime YAML from a normalized [ImportedProfile].
 *
 * Pipeline: build Kotlin Map/List tree → SnakeYAML dump → round-trip parse validation.
 * No manual YAML string construction; indentation is entirely SnakeYAML's responsibility.
 */
internal object RuntimeConfigGenerator {

    data class GeneratedConfig(
        val yaml: String,
        val sha256Hex: String,
    )

    /**
     * Returns [Result.failure] if SnakeYAML rejects the object tree or if the
     * round-trip validation parse fails. Never throws.
     */
    fun generate(profile: ImportedProfile): Result<GeneratedConfig> = runCatching {
        VeerLog.parser(
            "[generator] building object tree:" +
                " ${profile.proxies.size} proxies" +
                " ${profile.proxyGroups.size} groups" +
                " ${profile.rules.size} rules"
        )
        val yamlText = buildObjectTree(profile).dumpToYaml()
        val hash     = sha256Hex(yamlText)
        VeerLog.parser(
            "[generator] OK hash=${hash.take(8)}… len=${yamlText.length}" +
                " preview=${yamlText.take(120).replace('\n', '↵')}"
        )
        GeneratedConfig(yaml = yamlText, sha256Hex = hash)
    }

    /**
     * Applies a validated per-profile DNS overlay to an already generated safe
     * config. INHERIT returns the base bytes unchanged so restoring the
     * provider DNS is exact.
     */
    fun applyDnsOverride(
        baseYaml: String,
        policy: DnsOverridePolicy,
    ): Result<GeneratedConfig> = runCatching {
        val normalized = policy.normalized()
        val issues = DnsOverrideValidator.validate(normalized)
        require(issues.isEmpty()) {
            issues.joinToString("; ") { it.diagnosticMessage() }
        }
        if (normalized.mode == DnsOverrideMode.INHERIT) {
            return@runCatching GeneratedConfig(
                yaml = baseYaml,
                sha256Hex = sha256Hex(baseYaml),
            )
        }

        val loaded = Yaml(SafeConstructor(LoaderOptions())).load<Any>(baseYaml)
        val root = loaded.asStringKeyMap("runtime config").toMutableMap()
        val dns = (root["dns"] as? Map<*, *>)
            ?.asStringKeyMap("dns")
            ?.toMutableMap()
            ?: linkedMapOf()

        dns["enable"] = true
        dns["ipv6"] = normalized.ipv6
        dns["enhanced-mode"] = normalized.enhancedMode.wireValue
        dns["default-nameserver"] = normalized.defaultNameservers
        dns["nameserver"] = normalized.nameservers
        if (normalized.fallbackNameservers.isEmpty()) {
            dns.remove("fallback")
            dns.remove("fallback-filter")
        } else {
            dns["fallback"] = normalized.fallbackNameservers
        }
        if (normalized.enhancedMode == DnsEnhancedMode.FAKE_IP) {
            dns.putIfAbsent("fake-ip-range", "198.18.0.1/16")
            dns.putIfAbsent(
                "fake-ip-filter",
                listOf("*.lan", "*.local", "localhost.ptlogin2.qq.com"),
            )
        } else {
            dns.remove("fake-ip-range")
        }
        root["dns"] = dns

        val yamlText = LinkedHashMap(root).dumpToYaml()
        GeneratedConfig(yaml = yamlText, sha256Hex = sha256Hex(yamlText))
    }

    // -------------------------------------------------------------------------
    // Object tree construction
    // -------------------------------------------------------------------------

    private fun buildObjectTree(profile: ImportedProfile): LinkedHashMap<String, Any> {
        val config = linkedMapOf<String, Any>()

        // Fixed infrastructure — the profile cannot override these
        config["mixed-port"]          = 7890
        config["mode"]                = "rule"
        config["log-level"]           = "warning"
        config["allow-lan"]           = false
        config["unified-delay"]       = true
        config["tcp-concurrent"]      = true

        // geo-auto-update is disabled: GeoDatabaseManager (asset bundle + network fallback)
        // owns initial delivery before the core starts. geox-url is kept as a fallback
        // reference in case the user enables auto-update; mirrors are ordered CN-accessible first.
        config["geo-auto-update"] = false
        config["geox-url"] = linkedMapOf(
            "mmdb"    to "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
            "geoip"   to "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
            "geosite" to "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
        )

        // Android owns routes and passes an already-established VPN fd to Veercore.
        // Mihomo defaults both auto-route and auto-detect-interface to true; omitting
        // this block starts a netlink NetworkUpdateMonitor that Android 14+ forbids.
        config["tun"] = linkedMapOf(
            "enable"                to false,
            // gVisor handles TCP and UDP fully in userspace. The system stack's
            // kernel TCP forwarder is unreliable with Android-owned TUN fds.
            "stack"                 to "gvisor",
            "device"                to "",
            "auto-route"            to false,
            "auto-detect-interface" to false,
            "inet4-address"          to listOf("172.19.0.1/30"),
            "inet6-address"          to listOf("fdfe:dcba:9876::1/126"),
            "dns-hijack"            to listOf("any:53"),
            "mtu"                   to 9000,
        )

        // Some Android apps resolve through their own DoH stack and therefore
        // connect to a real IP instead of Mihomo's fake-IP range. Recovering the
        // HTTP host / TLS SNI / QUIC SNI is required for domain and GEOSITE rules
        // (including AI-created OpenAI/Netflix routes) to keep working.
        config["sniffer"] = defaultSnifferConfig()

        config["dns"] = if (profile.dns != null) buildDnsMap(profile.dns)
                        else buildDefaultDnsMap()

        config["proxies"]      = profile.proxies.map { buildProxyMap(it) }
        config["proxy-groups"] = profile.proxyGroups.map { buildGroupMap(it) }
        config["rules"]        = profile.rules.map { it.toRuleString() }

        return config
    }

    private fun defaultSnifferConfig(): LinkedHashMap<String, Any> = linkedMapOf(
        "enable" to true,
        "force-dns-mapping" to true,
        "parse-pure-ip" to true,
        "override-destination" to true,
        "sniff" to linkedMapOf(
            "HTTP" to linkedMapOf(
                "ports" to listOf(80, "8080-8880"),
                "override-destination" to true,
            ),
            "TLS" to linkedMapOf(
                "ports" to listOf(443, 8443),
            ),
            "QUIC" to linkedMapOf(
                "ports" to listOf(443, 8443),
            ),
        ),
    )

    // -------------------------------------------------------------------------
    // SnakeYAML dump + round-trip validation
    // -------------------------------------------------------------------------

    private fun LinkedHashMap<String, Any>.dumpToYaml(): String {
        val options = DumperOptions().apply {
            defaultFlowStyle = DumperOptions.FlowStyle.BLOCK
            // indicatorIndent MUST be strictly less than indent.
            // With indent=4 indicatorIndent=2 the output matches standard Mihomo layout:
            //   proxies:
            //     - name: …
            //       type: …
            indent          = 4
            indicatorIndent = 2
            isPrettyFlow    = false
            isCanonical     = false
        }
        val yamlText = Yaml(options).dump(this)

        // Round-trip validation: re-parse to confirm the emitted text is valid YAML
        // before we hand it to the VPN service.
        runCatching {
            Yaml(SafeConstructor(LoaderOptions())).load<Any>(yamlText)
        }.onFailure { t ->
            VeerLog.parser(
                "[generator] round-trip validation FAILED: ${t.message}"
            )
            throw IllegalStateException("Generated YAML failed round-trip parse: ${t.message}", t)
        }.onSuccess {
            VeerLog.parser("[generator] round-trip validation OK")
        }

        return yamlText
    }

    private fun Any?.asStringKeyMap(label: String): LinkedHashMap<String, Any> {
        val source = this as? Map<*, *> ?: error("$label is not a YAML mapping")
        val result = linkedMapOf<String, Any>()
        source.forEach { (key, value) ->
            val stringKey = key as? String ?: error("$label contains a non-string key")
            if (value != null) result[stringKey] = value
        }
        return result
    }

    // -------------------------------------------------------------------------
    // Map builders — all return plain Map/List, never raw YAML text
    // -------------------------------------------------------------------------

    private fun buildProxyMap(proxy: NormalizedProxy): Map<String, Any> {
        val m = linkedMapOf<String, Any>()
        m["name"]   = proxy.name
        m["type"]   = proxy.type
        m["server"] = proxy.server
        m["port"]   = proxy.port
        if (proxy.udp) m["udp"] = true
        proxy.extras.forEach { (k, v) ->
            val any = v.toSnakeYamlAny()
            if (any != null) m[k] = any
        }
        return m
    }

    private fun buildGroupMap(group: NormalizedProxyGroup): Map<String, Any> {
        val m = linkedMapOf<String, Any>()
        m["name"]    = group.name
        m["type"]    = group.type
        m["proxies"] = group.proxies
        group.url?.let      { m["url"]       = it }
        group.interval?.let { m["interval"]  = it }
        group.tolerance?.let { m["tolerance"] = it }
        group.strategy?.let { m["strategy"]  = it }
        return m
    }

    private fun buildDnsMap(dns: NormalizedDns): Map<String, Any> {
        val m = linkedMapOf<String, Any>()
        val hardenProviderDns = dns.nameservers.none { it.isEncryptedDnsEndpoint() }
        m["enable"] = dns.enabled
        m["ipv6"]   = dns.ipv6
        dns.enhancedMode?.let       { m["enhanced-mode"]  = it }
        dns.fakeIpRange?.let        { m["fake-ip-range"]  = it }
        dns.useHosts?.let           { m["use-hosts"]      = it }
        if (dns.fakeDnsFilter.isNotEmpty())    m["fake-ip-filter"] = dns.fakeDnsFilter
        if (dns.defaultNameservers.isNotEmpty()) m["default-nameserver"] = dns.defaultNameservers
        m["nameserver"] = securePrimaryNameservers(dns)
        if (!hardenProviderDns && dns.fallbackNameservers.isNotEmpty()) {
            m["fallback"] = dns.fallbackNameservers
        }
        dns.fallbackFilter?.takeUnless { hardenProviderDns }?.let { filter ->
            val fm = linkedMapOf<String, Any>()
            filter.geoIp?.let { fm["geoip"] = it }
            filter.geoIpCode?.let { fm["geoip-code"] = it }
            if (filter.ipCidrs.isNotEmpty()) fm["ipcidr"] = filter.ipCidrs
            if (filter.domains.isNotEmpty()) fm["domain"] = filter.domains
            if (filter.geoSites.isNotEmpty()) fm["geosite"] = filter.geoSites
            if (fm.isNotEmpty()) m["fallback-filter"] = fm
        }
        return m
    }

    private fun buildDefaultDnsMap(): Map<String, Any> = linkedMapOf(
        "enable"         to true,
        "ipv6"           to false,
        "enhanced-mode"  to "fake-ip",
        "fake-ip-filter" to listOf("*.lan", "*.local", "localhost.ptlogin2.qq.com"),
        "default-nameserver" to listOf("223.5.5.5", "1.1.1.1"),
        "nameserver"     to BUILT_IN_SECURE_NAMESERVERS,
    )

    /**
     * Plain UDP/TCP resolvers can be transparently forged by the access network.
     * A poisoned answer may still look like a valid foreign address and therefore
     * evade geoip-based fallback filters, resulting in a TLS hostname mismatch.
     *
     * Custom DNS overrides remain fully user-controlled. For inherited provider
     * profiles, prefer an encrypted primary resolver supplied by the provider. If
     * none exists, use Veer's encrypted defaults; [buildDnsMap] also suppresses the
     * provider fallback/filter so it cannot re-select a censored answer. Plain
     * resolvers are retained as bootstrap servers only, where a forged answer
     * cannot bypass DoH certificate validation.
     */
    private fun securePrimaryNameservers(dns: NormalizedDns): List<String> {
        val encryptedPrimary = dns.nameservers.filter { it.isEncryptedDnsEndpoint() }
        if (encryptedPrimary.isNotEmpty()) return encryptedPrimary.distinct()
        return BUILT_IN_SECURE_NAMESERVERS
    }

    private fun String.isEncryptedDnsEndpoint(): Boolean {
        val scheme = substringBefore("://", missingDelimiterValue = "").lowercase()
        return scheme in setOf("https", "tls", "quic", "h3")
    }

    // -------------------------------------------------------------------------
    // SHA-256
    // -------------------------------------------------------------------------

    fun sha256Hex(text: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }

    private val BUILT_IN_SECURE_NAMESERVERS = listOf(
        "https://1.1.1.1/dns-query",
        "https://cloudflare-dns.com/dns-query",
    )
}
