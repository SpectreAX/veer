package com.yamax.veer.testing

import android.app.KeyguardManager
import android.os.Build
import android.os.PowerManager
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.core_compatibility.BackgroundRestrictionPolicy
import com.yamax.veer.core_compatibility.OemFamily
import org.junit.Assume.assumeFalse
import org.junit.rules.TestRule
import org.junit.runner.Description
import org.junit.runners.model.Statement

/**
 * Prevents host-driven Compose tests from hanging when the device cannot grant
 * a focused test window. HyperOS/Xiaomi is skipped because it can report an
 * interactive screen while still denying focus to the synthetic host Activity.
 */
internal class InteractiveComposeDeviceRule : TestRule {
    override fun apply(base: Statement, description: Description): Statement =
        object : Statement() {
            override fun evaluate() {
                val context = InstrumentationRegistry.getInstrumentation().targetContext
                val keyguard = context.getSystemService(KeyguardManager::class.java)
                val powerManager = context.getSystemService(PowerManager::class.java)
                val isXiaomi = BackgroundRestrictionPolicy.classifyOem(
                    Build.MANUFACTURER,
                    Build.BRAND,
                ) == OemFamily.XIAOMI
                assumeFalse(
                    "Compose host window cannot receive focus on this device",
                    keyguard?.isDeviceLocked == true ||
                        powerManager?.isInteractive != true ||
                        isXiaomi,
                )
                base.evaluate()
            }
        }
}
