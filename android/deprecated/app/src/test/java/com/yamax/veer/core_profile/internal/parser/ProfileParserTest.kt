package com.yamax.veer.core_profile.internal.parser

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

class ProfileParserTest {
    @Test
    fun subscriptionDisplayNameDoesNotExposePathQueryOrNestedUrl() {
        val url = "https://api.example.com/sub?target=clash&url=https%3A%2F%2Fsecret.example%2Ftoken"

        assertEquals("api.example.com", ProfileParser.subscriptionDisplayName(url))
    }

    @Test
    fun legacyLeakingSubscriptionDisplayNameIsSanitizedButCustomNameIsPreserved() {
        val url = "https://api.example.com/sub?token=secret"

        assertEquals(
            "api.example.com",
            ProfileParser.sanitizeSubscriptionDisplayName(
                "sub?target=clash&url=https%3A%2F%2Fsecret.example%2Ftoken",
                url,
            ),
        )
        assertEquals(
            "My Airport",
            ProfileParser.sanitizeSubscriptionDisplayName("My Airport", url),
        )
    }

    @Test
    fun plaintextProviderDnsIsHardenedAgainstFallbackPollution() = runBlocking {
        val yaml = """
            proxies:
              - name: HK-01
                type: ss
                server: example.com
                port: 443
                cipher: aes-128-gcm
                password: test-password
            proxy-groups:
              - name: PROXY
                type: select
                proxies: [HK-01, DIRECT]
            dns:
              enable: true
              default-nameserver: [223.5.5.5]
              nameserver: [223.5.5.5]
              fallback: [https://1.1.1.1/dns-query]
              fallback-filter:
                geoip: true
                geoip-code: CN
                ipcidr: [240.0.0.0/4]
            rules:
              - MATCH,PROXY
        """.trimIndent()

        val result = ProfileParser.parse(ProfileInput.YamlBytes(yaml.toByteArray(), "valid.yaml"))

        assertTrue(result.toString(), result is ImportResult.Success)
        val generated = (result as ImportResult.Success).generatedYaml
        assertTrue(generated.contains("mixed-port: 7890"))
        assertTrue(generated.contains("HK-01"))
        assertTrue(generated.contains("default-nameserver:"))
        assertTrue(generated.contains("auto-route: false"))
        assertTrue(generated.contains("auto-detect-interface: false"))
        assertTrue(generated.contains("172.19.0.1/30"))
        val root = Yaml(SafeConstructor(LoaderOptions())).load<Map<String, Any>>(generated)
        val sniffer = root["sniffer"] as Map<*, *>
        assertEquals(true, sniffer["enable"])
        assertEquals(true, sniffer["parse-pure-ip"])
        assertEquals(true, sniffer["override-destination"])
        assertEquals(setOf("HTTP", "TLS", "QUIC"), (sniffer["sniff"] as Map<*, *>).keys)
        val dns = root["dns"] as Map<*, *>
        assertEquals(
            listOf(
                "https://1.1.1.1/dns-query",
                "https://cloudflare-dns.com/dns-query",
            ),
            dns["nameserver"],
        )
        assertFalse(dns.containsKey("fallback"))
        assertFalse(dns.containsKey("fallback-filter"))
    }

    @Test
    fun plaintextOnlyProviderDnsIsReplacedByEncryptedDefaults() = runBlocking {
        val yaml = """
            proxies:
              - name: US-01
                type: ss
                server: example.com
                port: 443
                cipher: aes-128-gcm
                password: test-password
            proxy-groups:
              - name: PROXY
                type: select
                proxies: [US-01]
            dns:
              enable: true
              default-nameserver: [223.5.5.5]
              nameserver: [223.5.5.5, 119.29.29.29]
            rules:
              - MATCH,PROXY
        """.trimIndent()

        val result = ProfileParser.parse(ProfileInput.YamlBytes(yaml.toByteArray(), "dns.yaml"))

        assertTrue(result.toString(), result is ImportResult.Success)
        val generated = (result as ImportResult.Success).generatedYaml
        val root = Yaml(SafeConstructor(LoaderOptions())).load<Map<String, Any>>(generated)
        val dns = root["dns"] as Map<*, *>
        assertEquals(
            listOf(
                "https://1.1.1.1/dns-query",
                "https://cloudflare-dns.com/dns-query",
            ),
            dns["nameserver"],
        )
    }

    @Test
    fun cleartextSubscriptionUrlIsRejectedBeforeNetworkAccess() = runBlocking {
        val result = ProfileParser.parse(ProfileInput.SubscriptionUrl("http://example.com/sub"))

        assertTrue(result is ImportResult.Failure)
        val errors = (result as ImportResult.Failure).errors
        assertTrue(errors.single() is ValidationError.InvalidSubscriptionUrl)
    }

    @Test
    fun oversizedLocalProfileIsRejectedBeforeYamlParsing() = runBlocking {
        val bytes = ByteArray(ProfileImportPolicy.MAX_PROFILE_BYTES + 1)

        val result = ProfileParser.parse(ProfileInput.YamlBytes(bytes, "oversized.yaml"))

        assertTrue(result is ImportResult.Failure)
        val errors = (result as ImportResult.Failure).errors
        assertTrue(errors.single() is ValidationError.ProfileTooLarge)
    }

    @Test
    fun brokenProxyGroupReferenceIsRejected() = runBlocking {
        val yaml = """
            proxies:
              - name: HK-01
                type: ss
                server: example.com
                port: 443
                cipher: aes-128-gcm
                password: test-password
            proxy-groups:
              - name: PROXY
                type: select
                proxies: [MISSING]
            rules:
              - MATCH,PROXY
        """.trimIndent()

        val result = ProfileParser.parse(ProfileInput.YamlBytes(yaml.toByteArray(), "broken.yaml"))

        assertTrue(result is ImportResult.Failure)
        val errors = (result as ImportResult.Failure).errors
        assertTrue(errors.any { it is ValidationError.BrokenGroupReference })
    }

    @Test
    fun anyTlsNodeKeepsItsRequiredCredentialAndTlsOptions() = runBlocking {
        val yaml = """
            proxies:
              - name: AnyTLS-01
                type: anytls
                server: example.com
                port: 443
                password: test-password
                sni: edge.example.com
                client-fingerprint: chrome
            proxy-groups:
              - name: PROXY
                type: select
                proxies: [AnyTLS-01, DIRECT]
            rules:
              - MATCH,PROXY
        """.trimIndent()

        val result = ProfileParser.parse(ProfileInput.YamlBytes(yaml.toByteArray(), "anytls.yaml"))

        assertTrue(result.toString(), result is ImportResult.Success)
        val generated = Yaml(SafeConstructor(LoaderOptions()))
            .load<Map<String, Any>>((result as ImportResult.Success).generatedYaml)
        val proxy = (generated["proxies"] as List<*>).first() as Map<*, *>
        assertEquals("anytls", proxy["type"])
        assertEquals("test-password", proxy["password"])
        assertEquals("edge.example.com", proxy["sni"])
        assertEquals("chrome", proxy["client-fingerprint"])
        val missingPassword = ProfileParser.parse(
            ProfileInput.YamlBytes(
                yaml.replace("password: test-password", "").toByteArray(),
                "anytls-missing-password.yaml",
            ),
        )
        assertTrue(missingPassword is ImportResult.Failure)
        assertTrue((missingPassword as ImportResult.Failure).errors.any {
            it is ValidationError.MissingRequiredField
        })
    }

    @Test
    fun subscriptionMetadataRowsAreRemovedFromGeneratedAutomaticGroups() = runBlocking {
        val yaml = """
            proxies:
              - name: 套餐到期：长期有效
                type: trojan
                server: status.invalid
                port: 443
                password: status
              - name: JP-01
                type: ss
                server: jp.example.com
                port: 443
                cipher: aes-128-gcm
                password: test-password
            proxy-groups:
              - name: 自动选择
                type: url-test
                proxies: [套餐到期：长期有效, JP-01]
                url: https://www.gstatic.com/generate_204
            rules:
              - MATCH,自动选择
        """.trimIndent()

        val result = ProfileParser.parse(ProfileInput.YamlBytes(yaml.toByteArray(), "metadata.yaml"))

        assertTrue(result.toString(), result is ImportResult.Success)
        val generated = (result as ImportResult.Success).generatedYaml
        assertFalse(generated.contains("套餐到期：长期有效"))
        assertTrue(generated.contains("JP-01"))
    }
}
