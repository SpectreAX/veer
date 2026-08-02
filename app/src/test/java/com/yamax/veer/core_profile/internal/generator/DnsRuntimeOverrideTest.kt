package com.yamax.veer.core_profile.internal.generator

import com.yamax.veer.core_profile.DnsEnhancedMode
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

class DnsRuntimeOverrideTest {
    @Test
    fun `inherit preserves the exact base bytes`() {
        val result = RuntimeConfigGenerator.applyDnsOverride(
            BASE_CONFIG,
            DnsOverridePolicy(),
        ).getOrThrow()

        assertEquals(BASE_CONFIG, result.yaml)
        assertEquals(RuntimeConfigGenerator.sha256Hex(BASE_CONFIG), result.sha256Hex)
    }

    @Test
    fun `custom DNS replaces resolver fields and preserves routing tree`() {
        val result = RuntimeConfigGenerator.applyDnsOverride(
            BASE_CONFIG,
            DnsOverridePolicy(
                mode = DnsOverrideMode.CUSTOM,
                ipv6 = true,
                enhancedMode = DnsEnhancedMode.REDIR_HOST,
                defaultNameservers = listOf("1.1.1.1"),
                nameservers = listOf("https://dns.example/dns-query"),
                fallbackNameservers = listOf("tls://8.8.8.8:853"),
            ),
        ).getOrThrow()
        val root = parse(result.yaml)
        val dns = root["dns"] as Map<*, *>

        assertEquals(true, dns["enable"])
        assertEquals(true, dns["ipv6"])
        assertEquals("redir-host", dns["enhanced-mode"])
        assertEquals(listOf("1.1.1.1"), dns["default-nameserver"])
        assertEquals(listOf("https://dns.example/dns-query"), dns["nameserver"])
        assertEquals(listOf("tls://8.8.8.8:853"), dns["fallback"])
        assertFalse(dns.containsKey("fake-ip-range"))
        assertEquals((parse(BASE_CONFIG)["proxies"]), root["proxies"])
        assertEquals((parse(BASE_CONFIG)["proxy-groups"]), root["proxy-groups"])
        assertEquals((parse(BASE_CONFIG)["rules"]), root["rules"])
    }

    @Test
    fun `fake ip supplies safe defaults and empty fallback removes stale filter`() {
        val result = RuntimeConfigGenerator.applyDnsOverride(
            BASE_CONFIG,
            DnsOverridePolicy(
                mode = DnsOverrideMode.CUSTOM,
                enhancedMode = DnsEnhancedMode.FAKE_IP,
                defaultNameservers = listOf("223.5.5.5"),
                nameservers = listOf("223.5.5.5"),
            ),
        ).getOrThrow()
        val dns = parse(result.yaml)["dns"] as Map<*, *>

        assertEquals("198.18.0.1/16", dns["fake-ip-range"])
        assertTrue((dns["fake-ip-filter"] as List<*>).isNotEmpty())
        assertFalse(dns.containsKey("fallback"))
        assertFalse(dns.containsKey("fallback-filter"))
    }

    @Suppress("UNCHECKED_CAST")
    private fun parse(yaml: String): Map<String, Any> =
        Yaml(SafeConstructor(LoaderOptions())).load<Any>(yaml) as Map<String, Any>

    private companion object {
        val BASE_CONFIG = """
            mixed-port: 7890
            dns:
              enable: true
              ipv6: false
              enhanced-mode: fake-ip
              fake-ip-range: 198.18.0.1/16
              nameserver: [223.5.5.5]
              fallback: [https://1.1.1.1/dns-query]
              fallback-filter:
                geoip: true
            proxies:
              - name: test
                type: ss
                server: example.com
                port: 443
            proxy-groups:
              - name: PROXY
                type: select
                proxies: [test]
            rules:
              - MATCH,PROXY
        """.trimIndent() + "\n"
    }
}
