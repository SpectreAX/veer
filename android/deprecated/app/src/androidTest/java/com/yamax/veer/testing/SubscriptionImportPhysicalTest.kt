package com.yamax.veer.testing

import android.os.ParcelFileDescriptor
import android.net.VpnService
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.MihomoLocalProxy
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.SubscriptionMetadata
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import com.yamax.veer.core_profile.internal.parser.SubscriptionFetchResult
import com.yamax.veer.core_profile.internal.parser.UrlFetcher
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.Request
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.util.concurrent.TimeUnit

/**
 * Opt-in end-to-end subscription import using a non-logged device-side secret.
 * The host writes the URL to [SECRET_PATH] through stdin and the test removes it
 * after reading, so neither instrumentation arguments nor reports expose it.
 */
@RunWith(AndroidJUnit4::class)
class SubscriptionImportPhysicalTest {
    @Test(timeout = 180_000L)
    fun anyTlsNodeSmokeRestoresOriginalProfile() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("VPN consent must be granted first", VpnService.prepare(context) == null)
        val original = withTimeout(10_000) {
            ProfileManager.active.first { it != null }!!.profileId
        }
        val url = try {
            shell("cat $SECRET_PATH").trim()
        } finally {
            shell("rm -f $SECRET_PATH")
        }
        assertTrue("Ephemeral subscription secret was missing", url.isNotBlank())
        val fetched = UrlFetcher.fetch(url) as? SubscriptionFetchResult.Success
        assertTrue("Subscription fetch failed", fetched != null)
        val root = Yaml(SafeConstructor(LoaderOptions()))
            .load<Map<String, Any>>(String(fetched!!.bytes, Charsets.UTF_8))
        val nodes = (root["proxies"] as List<*>).filterIsInstance<Map<*, *>>()
            .filter { it["type"] == "anytls" &&
                !SubscriptionMetadata.isLikelyMetadataName(it["name"].toString()) }
        assertTrue("Subscription contained no usable AnyTLS nodes", nodes.isNotEmpty())
        val nodeNames = nodes.map { it["name"] as String }
        val group = "__VEER_ANYTLS_SMOKE__"
        val smokeYaml = Yaml().dump(
            linkedMapOf(
                "proxies" to nodes,
                "proxy-groups" to listOf(mapOf(
                    "name" to group,
                    "type" to "select",
                    "proxies" to nodeNames + "DIRECT",
                )),
                "rules" to listOf("MATCH,$group"),
            ),
        )
        val imported = ProfileManager.import(
            context,
            ProfileInput.YamlBytes(smokeYaml.toByteArray(), "anytls-smoke.yaml"),
        ) as? ImportResult.Success
        assertTrue("Temporary AnyTLS profile import failed", imported != null)
        val smokeId = imported!!.profile.id
        try {
            assertTrue("Temporary AnyTLS profile activation failed", ProfileManager.activate(context, smokeId))
            context.startForegroundService(VeerVpnService.startIntent(context))
            withTimeout(30_000) { MihomoEngine.state.first { it is EngineState.Running } }
            val client = MihomoLocalProxy.clientBuilder()
                .callTimeout(3, TimeUnit.SECONDS)
                .retryOnConnectionFailure(false)
                .build()
            var working = false
            for (nodeName in nodeNames) {
                if (!MihomoRepository.get().selectProxy(group, nodeName)) continue
                working = runCatching {
                    client.newCall(Request.Builder()
                        .url("https://www.gstatic.com/generate_204")
                        .get()
                        .build()).execute().use { it.code == 204 }
                }.getOrDefault(false)
                if (working) break
            }
            assertTrue("No usable AnyTLS exit among ${nodeNames.size} nodes", working)
        } finally {
            context.startForegroundService(VeerVpnService.stopIntent(context))
            withTimeout(30_000) { MihomoEngine.state.first { it is EngineState.Stopped } }
            assertTrue("Original profile restoration failed", ProfileManager.activate(context, original))
            ProfileManager.delete(context, smokeId)
        }
    }

    @Test(timeout = 120_000L)
    fun importsAndActivatesSubscriptionFromEphemeralSecret() {
        assumeTrue(
            "Subscription import requires -e restoreSubscription true",
            InstrumentationRegistry.getArguments()
                .getString("restoreSubscription")
                .equals("true", ignoreCase = true),
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val url = try {
            shell("cat $SECRET_PATH").trim()
        } finally {
            shell("rm -f $SECRET_PATH")
        }
        assertTrue("Ephemeral subscription secret was missing", url.isNotBlank())

        val result = runBlocking {
            ProfileManager.import(context, ProfileInput.SubscriptionUrl(url))
        }
        assertTrue("Subscription import failed", result is ImportResult.Success)
        val success = result as ImportResult.Success
        assertTrue("Imported subscription did not contain proxies", success.profile.metadata.proxyCount > 0)
        assertTrue(
            "Imported subscription could not be activated",
            runBlocking { ProfileManager.activate(context, success.profile.id) },
        )
        assertTrue(
            "Activated profile was not published",
            ProfileManager.active.value?.profileId == success.profile.id,
        )
    }

    private fun shell(command: String): String {
        val descriptor = InstrumentationRegistry.getInstrumentation()
            .uiAutomation
            .executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor)
            .bufferedReader()
            .use { it.readText() }
    }

    private companion object {
        const val SECRET_PATH = "/data/local/tmp/veer-subscription-url"
    }
}
