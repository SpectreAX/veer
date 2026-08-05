package com.yamax.veer.testing

import android.app.Activity
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.MainActivity
import com.yamax.veer.ui.nodes.NodesActivity
import com.yamax.veer.ui.profile.ProfileActivity
import com.yamax.veer.ui.rules.RulesActivity
import com.yamax.veer.ui.settings.SettingsActivity
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TopLevelNavigationInstrumentedTest {

    @Test
    fun systemBackFromEverySecondaryTabReturnsHome() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val topLevelActivities = listOf(
            NodesActivity::class.java,
            RulesActivity::class.java,
            ProfileActivity::class.java,
            SettingsActivity::class.java,
        )

        topLevelActivities.forEach { activityClass ->
            val monitor = instrumentation.addMonitor(MainActivity::class.java.name, null, false)
            try {
                ActivityScenario.launch(activityClass).use { scenario ->
                    instrumentation.waitForIdleSync()
                    scenario.onActivity { activity ->
                        activity.onBackPressedDispatcher.onBackPressed()
                    }

                    val home = monitor.waitForActivityWithTimeout(HOME_TIMEOUT_MS)
                    assertNotNull(
                        "System back from ${activityClass.simpleName} did not open MainActivity",
                        home,
                    )
                    home?.finishOnMainThread(instrumentation)
                }
            } finally {
                instrumentation.removeMonitor(monitor)
            }
        }
    }

    private fun Activity.finishOnMainThread(
        instrumentation: android.app.Instrumentation,
    ) {
        instrumentation.runOnMainSync(::finish)
        instrumentation.waitForIdleSync()
    }

    private companion object {
        const val HOME_TIMEOUT_MS = 3_000L
    }
}
