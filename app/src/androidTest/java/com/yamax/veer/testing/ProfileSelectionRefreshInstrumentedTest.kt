package com.yamax.veer.testing

import android.net.VpnService
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_mihomo.ProfileSelectionStore
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import com.yamax.veer.core_profile.internal.storage.ProfileStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Device regression: a refreshed profile must not restore a removed selector member. */
@RunWith(AndroidJUnit4::class)
class ProfileSelectionRefreshInstrumentedTest {
    @Test(timeout = 180_000)
    fun removedNodeIsPrunedAfterProfileUpdateAndVpnRestart() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("VPN consent must be granted first", VpnService.prepare(context) == null)
        val previous = ProfileStore.loadIndex(context).active?.profileId
        var testId: ProfileId? = null
        try {
            stop(context)
            val first = ProfileManager.import(
                context, ProfileInput.YamlBytes(config("TO_DELETE"), "selection-refresh.yaml"),
            ) as ImportResult.Success
            testId = first.profile.id
            assertTrue(ProfileManager.activate(context, testId))
            start(context)

            val repository = MihomoRepository.get()
            assertTrue(repository.selectProxy("PROXY", "TO_DELETE"))
            val home = File(context.noBackupFilesDir, "proxy-selections")
            assertEquals("TO_DELETE", ProfileSelectionStore.read(home, testId.value)["PROXY"])

            stop(context)
            val updated = ProfileManager.import(
                context, ProfileInput.YamlBytes(config("REPLACEMENT"), "selection-refresh.yaml"),
                existingId = testId,
            )
            assertTrue("Updated config must retain the same profile", updated is ImportResult.Success)
            start(context)

            val group = repository.routingSnapshot().proxies["PROXY"]!!
            assertEquals(listOf("DIRECT", "REPLACEMENT"), group.members)
            assertEquals("DIRECT", group.now)
            assertFalse(ProfileSelectionStore.read(home, testId.value).containsKey("PROXY"))
        } finally {
            stop(context)
            if (previous != null) ProfileManager.activate(context, previous)
            testId?.let { ProfileManager.delete(context, it) }
        }
    }

    private suspend fun start(context: android.content.Context) {
        context.startForegroundService(VeerVpnService.startIntent(context))
        withTimeout(30_000) { MihomoEngine.state.first { it is EngineState.Running } }
        assertTrue(MihomoRepository.get().controllerReady())
    }

    private suspend fun stop(context: android.content.Context) {
        if (MihomoEngine.state.value is EngineState.Stopped) return
        context.startForegroundService(VeerVpnService.stopIntent(context))
        withTimeout(30_000) { MihomoEngine.state.first { it is EngineState.Stopped } }
    }

    private fun config(node: String): ByteArray = buildString {
        appendLine("proxies:")
        appendLine("  - name: $node")
        appendLine("    type: http")
        appendLine("    server: 127.0.0.1")
        appendLine("    port: 65534")
        appendLine("proxy-groups:")
        appendLine("  - name: PROXY")
        appendLine("    type: select")
        appendLine("    proxies:")
        appendLine("      - DIRECT")
        appendLine("      - $node")
        appendLine("dns:")
        appendLine("  enable: true")
        appendLine("  nameserver:")
        appendLine("    - 223.5.5.5")
        appendLine("rules:")
        appendLine("  - MATCH,DIRECT")
    }.toByteArray()
}
