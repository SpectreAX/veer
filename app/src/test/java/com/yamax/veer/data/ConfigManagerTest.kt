package com.yamax.veer.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

class ConfigManagerTest {

    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun `new policy replaces an existing rule for the same matcher`() {
        val (rules, changed) = ConfigManager.upsertAiRule(
            existing = listOf("DOMAIN-SUFFIX,iana.org,PROXY", "MATCH,PROXY"),
            rule = "DOMAIN-SUFFIX,iana.org,DIRECT",
        )

        assertTrue(changed)
        assertEquals(listOf("MATCH,PROXY", "DOMAIN-SUFFIX,iana.org,DIRECT"), rules)
    }

    @Test
    fun `batch rule upsert produces one store and per-operation change results`() {
        val before = AiRuleStore(
            enabled = listOf("DOMAIN-SUFFIX,existing.example,DIRECT"),
            disabled = listOf("GEOSITE,netflix,OLD"),
        )

        val (after, changes) = ConfigManager.upsertAiRules(
            before,
            listOf(
                "GEOSITE,netflix,JP",
                "GEOSITE,youtube,US",
                "DOMAIN-SUFFIX,existing.example,DIRECT",
            ),
        )

        assertEquals(listOf(true, true, false), changes)
        assertEquals(
            listOf(
                "DOMAIN-SUFFIX,existing.example,DIRECT",
                "GEOSITE,netflix,JP",
                "GEOSITE,youtube,US",
            ),
            after.enabled,
        )
        assertTrue(after.disabled.isEmpty())
        assertEquals(before, AiRuleStore(
            enabled = listOf("DOMAIN-SUFFIX,existing.example,DIRECT"),
            disabled = listOf("GEOSITE,netflix,OLD"),
        ))
    }

    @Test
    fun `AI rules are prepended and deduplicated`() {
        val merged = ConfigManager.mergeAiRules(
            baseYaml = """
                mode: rule
                rules:
                  - DOMAIN-SUFFIX,example.com,PROXY
                  - MATCH,PROXY
            """.trimIndent(),
            aiRules = listOf(
                "DOMAIN-SUFFIX,v2ex.com,DIRECT",
                "DOMAIN-SUFFIX,v2ex.com,DIRECT",
            ),
        )

        val rules = parse(merged)["rules"] as List<*>
        assertEquals(
            listOf(
                "DOMAIN-SUFFIX,v2ex.com,DIRECT",
                "DOMAIN-SUFFIX,example.com,PROXY",
                "MATCH,PROXY",
            ),
            rules,
        )
    }

    @Test
    fun `runtime materialization enables domain sniffing for existing profiles`() {
        val merged = ConfigManager.mergeAiRules(
            baseYaml = """
                mode: rule
                sniffer:
                  enable: false
                rules:
                  - MATCH,DIRECT
            """.trimIndent(),
            aiRules = emptyList(),
        )

        val sniffer = parse(merged)["sniffer"] as Map<*, *>
        assertEquals(true, sniffer["enable"])
        assertEquals(true, sniffer["force-dns-mapping"])
        assertEquals(true, sniffer["parse-pure-ip"])
        assertEquals(true, sniffer["override-destination"])
        val protocols = sniffer["sniff"] as Map<*, *>
        assertEquals(setOf("HTTP", "TLS", "QUIC"), protocols.keys)
        assertEquals(listOf(443, 8443), (protocols["TLS"] as Map<*, *>)["ports"])
    }

    @Test
    fun `legacy AI provider is removed during migration`() {
        val merged = ConfigManager.mergeAiRules(
            baseYaml = """
                rule-providers:
                  ai_override_provider:
                    type: file
                  retained:
                    type: http
                rules:
                  - RULE-SET,ai_override_provider,DIRECT
                  - RULE-SET,retained,PROXY
                  - MATCH,DIRECT
            """.trimIndent(),
            aiRules = listOf("DOMAIN,example.org,DIRECT"),
        )

        val config = parse(merged)
        val providers = config["rule-providers"] as Map<*, *>
        assertFalse(providers.containsKey("ai_override_provider"))
        assertTrue(providers.containsKey("retained"))
        assertEquals(
            listOf("DOMAIN,example.org,DIRECT", "RULE-SET,retained,PROXY", "MATCH,DIRECT"),
            config["rules"],
        )
    }

    @Test
    fun `subscription metadata proxies are removed from existing runtime configs`() {
        val merged = ConfigManager.mergeAiRules(
            baseYaml = """
                proxies:
                  - name: 套餐到期：长期有效
                    type: trojan
                    server: status.invalid
                    port: 443
                  - name: JP-01
                    type: vless
                    server: jp.example.com
                    port: 443
                proxy-groups:
                  - name: 自动选择
                    type: url-test
                    proxies: [套餐到期：长期有效, JP-01]
                    url: https://www.gstatic.com/generate_204
                rules:
                  - MATCH,自动选择
            """.trimIndent(),
            aiRules = emptyList(),
        )

        val config = parse(merged)
        val proxies = config["proxies"] as List<*>
        val proxyNames = proxies.map { (it as Map<*, *>)["name"] }
        assertEquals(listOf("JP-01"), proxyNames)
        val groups = config["proxy-groups"] as List<*>
        val members = (groups.single() as Map<*, *>)["proxies"]
        assertEquals(listOf("JP-01"), members)
    }

    @Test
    fun `AI rules for nodes missing from the active profile are skipped`() {
        val merged = ConfigManager.mergeAiRules(
            baseYaml = """
                proxies:
                  - name: JP-NEW
                    type: vless
                    server: jp.example.com
                    port: 443
                proxy-groups:
                  - name: PROXY
                    type: select
                    proxies: [JP-NEW]
                rules:
                  - MATCH,PROXY
            """.trimIndent(),
            aiRules = listOf(
                "GEOSITE,netflix,JP-NEW",
                "DOMAIN-SUFFIX,skk.moe,US-OLD",
                "DOMAIN-SUFFIX,v2ex.com,DIRECT",
            ),
        )

        val rules = parse(merged)["rules"] as List<*>
        assertEquals(
            listOf(
                "GEOSITE,netflix,JP-NEW",
                "DOMAIN-SUFFIX,v2ex.com,DIRECT",
                "MATCH,PROXY",
            ),
            rules,
        )
    }

    @Test
    fun `legacy global rules migrate exactly once to the active profile scope`() {
        val home = temporaryFolder.newFolder("mihomo")
        java.io.File(home, ConfigManager.AI_OVERRIDE).writeText(
            """
                payload:
                  - DOMAIN-SUFFIX,example.com,DIRECT
                  - GEOSITE,youtube,PROXY
            """.trimIndent()
        )

        assertTrue(ConfigManager.migrateLegacyRules(home, "profile-a"))
        val profileA = ConfigManager.scopedAiRulesFile(home, "profile-a")
        val profileB = ConfigManager.scopedAiRulesFile(home, "profile-b")

        assertTrue(profileA.exists())
        assertTrue(profileA.readText().contains("DOMAIN-SUFFIX,example.com,DIRECT"))
        assertFalse(profileB.exists())
        assertFalse(ConfigManager.migrateLegacyRules(home, "profile-b"))
        assertFalse(profileB.exists())
    }

    @Test
    fun `profile scopes always resolve to independent safe files`() {
        val home = temporaryFolder.newFolder("scopes")

        val profileA = ConfigManager.scopedAiRulesFile(home, "profile-a")
        val profileB = ConfigManager.scopedAiRulesFile(home, "profile-b")
        val unsafe = ConfigManager.scopedAiRulesFile(home, "../outside")

        assertNotEquals(profileA.absolutePath, profileB.absolutePath)
        assertEquals("ai_rules", profileA.parentFile?.name)
        assertTrue(unsafe.parentFile == profileA.parentFile)
        assertFalse(unsafe.name.contains(".."))
    }

    @Test
    fun `rule store keeps disabled rules backward compatibly`() {
        val file = temporaryFolder.newFile("rules.yaml")
        file.writeText(
            """
                payload:
                  - DOMAIN-SUFFIX,example.com,DIRECT
                disabled-payload:
                  - GEOSITE,netflix,PROXY
            """.trimIndent(),
        )

        val store = ConfigManager.readAiRuleStore(file)

        assertEquals(listOf("DOMAIN-SUFFIX,example.com,DIRECT"), store.enabled)
        assertEquals(listOf("GEOSITE,netflix,PROXY"), store.disabled)
        val roundTrip = temporaryFolder.newFile("round-trip.yaml")
        roundTrip.writeText(ConfigManager.dumpAiRuleStore(store))
        assertEquals(store, ConfigManager.readAiRuleStore(roundTrip))
    }

    @Test
    fun `enable disable delete and rebind preserve one matcher`() {
        val raw = "DOMAIN-SUFFIX,example.com,PROXY"
        val id = ConfigManager.parseAiRule(raw)!!.id
        val original = AiRuleStore(enabled = listOf(raw))

        val disabled = ConfigManager.setRuleEnabled(original, id, enabled = false)
        assertTrue(disabled.enabled.isEmpty())
        assertEquals(listOf(raw), disabled.disabled)

        val rebound = ConfigManager.rebindRule(disabled, id, "DIRECT")
        assertEquals(listOf("DOMAIN-SUFFIX,example.com,DIRECT"), rebound.disabled)

        val enabled = ConfigManager.setRuleEnabled(rebound, id, enabled = true)
        assertEquals(listOf("DOMAIN-SUFFIX,example.com,DIRECT"), enabled.enabled)
        assertTrue(enabled.disabled.isEmpty())

        val deleted = ConfigManager.deleteRule(enabled, id)
        assertTrue(deleted.enabled.isEmpty())
        assertTrue(deleted.disabled.isEmpty())
    }

    @Test
    fun `rule parser keeps trailing Mihomo modifiers when policy changes`() {
        val raw = "IP-CIDR,203.0.113.0/24,PROXY,no-resolve"
        val parsed = ConfigManager.parseAiRule(raw)!!

        assertEquals("IP-CIDR", parsed.matchType)
        assertEquals("203.0.113.0/24", parsed.target)
        assertEquals("PROXY", parsed.policy)
        assertEquals(
            "IP-CIDR,203.0.113.0/24,DIRECT,no-resolve",
            ConfigManager.replaceRulePolicy(raw, "DIRECT"),
        )
    }

    @Test
    fun `policy inventory reads proxy and group names without parsing full config`() {
        val policies = ConfigManager.policyNamesFromYaml(
            """
                port: 7890
                proxies:
                  - name: "JP: 01"
                    type: vless
                  - name: 香港 01
                    type: trojan
                proxy-groups:
                  - name: 千速云
                    type: select
                    proxies: [香港 01]
                rules:
                  - MATCH,千速云
            """.trimIndent(),
        )

        assertTrue("JP: 01" in policies)
        assertTrue("香港 01" in policies)
        assertTrue("千速云" in policies)
        assertTrue("DIRECT" in policies)
        assertFalse("MATCH,千速云" in policies)
    }

    @Test
    fun `runtime default policy follows the final match rule`() {
        assertEquals(
            "千速云",
            ConfigManager.defaultPolicyFromRules(
                listOf(
                    "DOMAIN-SUFFIX,example.com,DIRECT",
                    "MATCH,千速云",
                ),
            ),
        )
        assertEquals(
            "Fallback",
            ConfigManager.defaultPolicyFromRules(listOf("FINAL,Fallback")),
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun parse(text: String): Map<String, Any?> =
        Yaml(SafeConstructor(LoaderOptions())).load(text) as Map<String, Any?>
}
