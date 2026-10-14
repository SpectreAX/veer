package com.yamax.veer.core_mihomo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.Callable
import java.util.concurrent.Executors

class ControllerSecretStoreTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun `secret is random persistent and scoped to installation`() {
        val firstDir = temporaryFolder.newFolder("first")
        val secondDir = temporaryFolder.newFolder("second")
        val first = ControllerSecretStore.getOrCreate(firstDir)

        assertTrue(Regex("[0-9a-f]{64}").matches(first))
        assertEquals(first, ControllerSecretStore.getOrCreate(firstDir))
        assertNotEquals(first, ControllerSecretStore.getOrCreate(secondDir))
    }

    @Test
    fun `concurrent readers cannot create different credentials`() {
        val dir = temporaryFolder.newFolder("concurrent")
        val pool = Executors.newFixedThreadPool(8)
        try {
            val values = pool.invokeAll((1..16).map {
                Callable { ControllerSecretStore.getOrCreate(dir) }
            }).map { it.get() }
            assertEquals(1, values.toSet().size)
        } finally {
            pool.shutdownNow()
        }
    }
}
