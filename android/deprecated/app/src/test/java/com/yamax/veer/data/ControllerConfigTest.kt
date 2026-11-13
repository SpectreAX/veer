package com.yamax.veer.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor

class ControllerConfigTest {
    @Test
    fun `final config replaces an empty or subscription supplied secret`() {
        val credential = "a".repeat(64)
        val yaml = """
            external-controller: 0.0.0.0:9090
            external-controller-tls: 0.0.0.0:9443
            external-controller-pipe: legacy-pipe
            secret: untrusted
            authentication: [guest:guess]
            skip-auth-prefixes: [127.0.0.1/8]
            rules: [MATCH,DIRECT]
        """.trimIndent()

        val result = ConfigManager.withControllerSecret(
            yaml, credential, "/data/user/0/com.yamax.veer/no_backup/mihomo-auth/controller.sock",
        )
        val root = Yaml(SafeConstructor(LoaderOptions())).load<Map<String, Any>>(result)
        assertEquals(credential, root["secret"])
        assertEquals(listOf("veer:$credential"), root["authentication"])
        assertEquals(emptyList<String>(), root["skip-auth-prefixes"])
        assertFalse(root.containsKey("external-controller"))
        assertFalse(root.containsKey("external-controller-tls"))
        assertFalse(root.containsKey("external-controller-pipe"))
        assertEquals(
            "/data/user/0/com.yamax.veer/no_backup/mihomo-auth/controller.sock",
            root["external-controller-unix"],
        )
        assertEquals(false, (root["profile"] as Map<*, *>)["store-selected"])
        assertFalse(result.contains("untrusted"))
    }
}
