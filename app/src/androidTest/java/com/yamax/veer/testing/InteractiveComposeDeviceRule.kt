package com.yamax.veer.testing

import android.app.KeyguardManager
import android.os.PowerManager
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume.assumeFalse
import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runners.model.Statement

/**
 * Prevents host-driven Compose tests from hanging when the device cannot grant
 * a focused test window. OEM identity alone is not a reason to skip: physical
 * Xiaomi/HyperOS devices must run the same UI assertions when awake and unlocked.
 */
internal class InteractiveComposeDeviceRule : TestRule {
    override fun apply(base: Statement, description: Description): Statement =
        object : Statement() {
            override fun evaluate() {
                val instrumentation = InstrumentationRegistry.getInstrumentation()
                val context = instrumentation.targetContext
                val keyguard = context.getSystemService(KeyguardManager::class.java)
                val powerManager = context.getSystemService(PowerManager::class.java)
                assumeFalse(
                    "Compose host window cannot receive focus on this device",
                    keyguard?.isDeviceLocked == true ||
                        powerManager?.isInteractive != true,
                )
                // ActivityScenario closes a target Activity by briefly launching
                // an invoker Activity from the test APK. HyperOS can leave that
                // helper task in front after the previous case, so the next
                // Compose tree exists but is not visible and touch injection is
                // delivered to the wrong window. The runner itself lives in the
                // target package, making it safe to clear only the test APK here.
                instrumentation.uiAutomation
                    .executeShellCommand("am force-stop ${instrumentation.context.packageName}")
                    .use { descriptor ->
                        android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor)
                            .use { it.readBytes() }
                    }
                base.evaluate()
            }
        }
}
