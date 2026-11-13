package com.yamax.veer.core_profile.internal.parser

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfigCompatibilityAuditTest {
    private val base = """
        mixed-port: 7890
        allow-lan: false
        proxies:
          - name: JP-01
            type: ss
            server: example.com
            port: 443
            cipher: aes-128-gcm
            password: test-password
        proxy-groups:
          - name: PROXY
            type: select
            proxies: [JP-01, DIRECT]
        rules:
          - DOMAIN-SUFFIX,example.org,PROXY
          - MATCH,PROXY
    """.trimIndent()

    @Test
    fun `ordinary profile and app owned runtime keys remain importable`() = runBlocking {
        assertTrue(ConfigCompatibilityAudit.audit(base).isEmpty())
        assertTrue(ProfileParser.parse(ProfileInput.YamlBytes(base.toByteArray(), "base.yaml")) is ImportResult.Success)
    }

    @Test
    fun `provider and group use are rejected with paths but not credentials`() = runBlocking {
        val yaml = base.replace(
            "proxies: [JP-01, DIRECT]",
            "proxies: [JP-01, DIRECT]\n    use: [remote-secret-provider]",
        ) + "\nproxy-providers:\n  remote-secret-provider:\n    url: https://example.com/private-token"
        val result = ProfileParser.parse(ProfileInput.YamlBytes(yaml.toByteArray(), "provider.yaml"))

        assertTrue(result is ImportResult.Failure)
        val error = (result as ImportResult.Failure).errors.single() as ValidationError.UnsupportedConfigFeatures
        assertEquals(listOf("proxy-providers", "proxy-groups[0].use"), error.paths)
        assertFalse(error.message().contains("private-token"))
        assertFalse(error.message().contains("remote-secret-provider"))
    }

    @Test
    fun `dns policy and complex rules cannot silently disappear`() {
        val yaml = base.replace(
            "  - MATCH,PROXY",
            "  - RULE-SET,streaming,PROXY\n  - DOMAIN-SUFFIX,example.net,PROXY,unexpected-option\n  - MATCH,PROXY",
        ) + "\ndns:\n  enable: true\n  nameserver-policy:\n    '+.example.org': https://dns.example/dns-query"

        assertEquals(
            listOf("rules[1]", "rules[2]", "dns.nameserver-policy"),
            ConfigCompatibilityAudit.audit(yaml),
        )
    }

    @Test
    fun `unknown rule target is rejected rather than removed`() = runBlocking {
        val yaml = base.replace("DOMAIN-SUFFIX,example.org,PROXY", "DOMAIN-SUFFIX,example.org,MISSING")
        val result = ProfileParser.parse(ProfileInput.YamlBytes(yaml.toByteArray(), "rule.yaml"))

        assertTrue(result is ImportResult.Failure)
        assertTrue((result as ImportResult.Failure).errors.any { it is ValidationError.BrokenRuleReference })
    }

    @Test
    fun `malformed list entries are reported rather than filtered`() {
        val yaml = base.replace("proxies: [JP-01, DIRECT]", "proxies: [JP-01, 42]")
        assertEquals(listOf("proxy-groups[0].proxies"), ConfigCompatibilityAudit.audit(yaml))
    }
}
