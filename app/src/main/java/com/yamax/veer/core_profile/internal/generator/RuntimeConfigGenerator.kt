package com.yamax.veer.core_profile.internal.generator

import com.yamax.veer.core_logging.VeerLog
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

    // -------------------------------------------------------------------------
    // Object tree construction
    // -------------------------------------------------------------------------

    private fun buildObjectTree(profile: ImportedProfile): LinkedHashMap<String, Any> {
        val config = linkedMapOf<String, Any>()

        // Fixed infrastructure — the profile cannot override these
        config["mixed-port"]          = 7890
        config["external-controller"] = "127.0.0.1:9090"
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

        config["dns"] = if (profile.dns != null) buildDnsMap(profile.dns)
                        else buildDefaultDnsMap()

        config["proxies"]      = profile.proxies.map { buildProxyMap(it) }
        config["proxy-groups"] = profile.proxyGroups.map { buildGroupMap(it) }
        config["rules"]        = profile.rules.map { it.toRuleString() }

        return config
    }

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
        m["enable"] = dns.enabled
        m["ipv6"]   = dns.ipv6
        dns.enhancedMode?.let       { m["enhanced-mode"]  = it }
        if (dns.fakeDnsFilter.isNotEmpty())    m["fake-ip-filter"] = dns.fakeDnsFilter
        if (dns.nameservers.isNotEmpty())      m["nameserver"]     = dns.nameservers
        if (dns.fallbackNameservers.isNotEmpty()) m["fallback"]    = dns.fallbackNameservers
        return m
    }

    private fun buildDefaultDnsMap(): Map<String, Any> = linkedMapOf(
        "enable"         to true,
        "ipv6"           to false,
        "enhanced-mode"  to "fake-ip",
        "fake-ip-filter" to listOf("*.lan", "*.local", "localhost.ptlogin2.qq.com"),
        "nameserver"     to listOf("223.5.5.5", "119.29.29.29"),
        "fallback"       to listOf("tls://1.1.1.1:853", "https://8.8.8.8/dns-query"),
    )

    // -------------------------------------------------------------------------
    // SHA-256
    // -------------------------------------------------------------------------

    fun sha256Hex(text: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { "%02x".format(it) }
    }
}
