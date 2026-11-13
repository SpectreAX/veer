package com.yamax.veer.testing

import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.data.ApiKeyStore
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Restores the user API credential through Android Keystore without logging it. */
@RunWith(AndroidJUnit4::class)
class ApiKeyRestorePhysicalTest {
    @Test
    fun encryptsApiKeyFromEphemeralSecret() {
        assumeTrue(
            "API key restore requires -e restoreApiKey true",
            InstrumentationRegistry.getArguments()
                .getString("restoreApiKey")
                .equals("true", ignoreCase = true),
        )
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val key = try {
            shell("cat $SECRET_PATH").trim()
        } finally {
            shell("rm -f $SECRET_PATH")
        }
        assertTrue("Ephemeral API secret was missing", key.isNotBlank())
        ApiKeyStore.setDeepseekKey(context, key)
        assertTrue("Encrypted API key could not be read back", ApiKeyStore.deepseekKey(context) == key)
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
        const val SECRET_PATH = "/data/local/tmp/veer-api-key"
    }
}
