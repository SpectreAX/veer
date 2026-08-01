package com.yamax.veer.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class PerAppProxyPolicyStoreTest {
    @Test
    fun `round trip normalizes selected packages`() {
        val directory = Files.createTempDirectory("veer-per-app").toFile()
        val file = directory.resolve("policy.json")
        try {
            PerAppProxyPolicyStore.write(
                file,
                PerAppProxyPolicy(
                    mode = PerAppProxyMode.BYPASS_SELECTED,
                    packageNames = setOf(" com.example.bank ", "", "com.example.browser"),
                ),
            )

            assertEquals(
                PerAppProxyPolicy(
                    mode = PerAppProxyMode.BYPASS_SELECTED,
                    packageNames = setOf("com.example.bank", "com.example.browser"),
                ),
                PerAppProxyPolicyStore.read(file),
            )
            assertTrue(file.readText().contains("\"schemaVersion\":1"))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun `corrupt file fails safe to all apps`() {
        val file = Files.createTempFile("veer-per-app-corrupt", ".json").toFile()
        try {
            file.writeText("{not-json")
            assertEquals(PerAppProxyPolicy(), PerAppProxyPolicyStore.read(file))
        } finally {
            file.delete()
        }
    }
}
