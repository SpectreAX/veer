package com.yamax.veer.testing

import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Opt-in end-to-end subscription import using a non-logged device-side secret.
 * The host writes the URL to [SECRET_PATH] through stdin and the test removes it
 * after reading, so neither instrumentation arguments nor reports expose it.
 */
@RunWith(AndroidJUnit4::class)
class SubscriptionImportPhysicalTest {
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
