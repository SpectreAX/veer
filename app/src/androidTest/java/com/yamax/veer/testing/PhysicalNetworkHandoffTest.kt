package com.yamax.veer.testing

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.ParcelFileDescriptor
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.core_diagnostics.DiagnosticCategory
import com.yamax.veer.core_diagnostics.NetworkDiagnosticExecutor
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.VeerVpnService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Destructive-to-connectivity physical-device coverage.
 *
 * This class is opt-in because it briefly disables Wi-Fi and mobile data. Run
 * it only on a connected device with:
 *
 * `-e physicalNetworkMatrix true -e class com.yamax.veer.testing.PhysicalNetworkHandoffTest`
 *
 * The original radio state is restored in `finally`, including on assertion
 * failure or instrumentation cancellation.
 */
@RunWith(AndroidJUnit4::class)
class PhysicalNetworkHandoffTest {
    private val instrumentation
        get() = InstrumentationRegistry.getInstrumentation()

    private val context: Context
        get() = instrumentation.targetContext

    private val connectivityManager: ConnectivityManager
        get() = context.getSystemService(ConnectivityManager::class.java)

    @Test(timeout = 180_000L)
    fun wifiCellularHandoffKeepsOneHealthyRuntimeWhenCarrierDataIsValidated() {
        assumeTrue(
            "Physical network matrix requires -e physicalNetworkMatrix true",
            InstrumentationRegistry.getArguments()
                .getString("physicalNetworkMatrix")
                .equals("true", ignoreCase = true),
        )
        assumeTrue("VPN consent must be granted before the matrix", VpnService.prepare(context) == null)

        val wifiInitiallyEnabled = shell("settings get global wifi_on").trim() == "1"
        val dataInitiallyEnabled = shell("settings get global mobile_data").trim() != "0"
        assumeTrue("Matrix starts from enabled Wi-Fi", wifiInitiallyEnabled)
        assumeTrue("Matrix requires enabled mobile data", dataInitiallyEnabled)

        try {
            ContextCompat.startForegroundService(context, VeerVpnService.startIntent(context))
            assertNotNull("VPN did not reach Running", awaitRunning(15_000L))
            assertTrue("Wi-Fi never became validated", awaitTransport(NetworkCapabilities.TRANSPORT_WIFI))
            assertHealthy("Wi-Fi baseline")

            shell("svc wifi disable")
            assumeTrue(
                "Carrier data did not become validated (captive portal, inactive plan, or no signal)",
                awaitTransport(NetworkCapabilities.TRANSPORT_CELLULAR, timeoutMs = 45_000L),
            )
            assertTrue("Core left Running during Wi-Fi to cellular handoff", isRunning())
            assertHealthy("cellular handoff", timeoutMs = 30_000L)
        } finally {
            shell(if (dataInitiallyEnabled) "svc data enable" else "svc data disable")
            shell(if (wifiInitiallyEnabled) "svc wifi enable" else "svc wifi disable")
            ContextCompat.startForegroundService(context, VeerVpnService.stopIntent(context))
            runBlocking {
                withTimeoutOrNull(12_000L) {
                    MihomoEngine.state.first { it is EngineState.Stopped }
                }
            }
        }
    }

    @Test(timeout = 120_000L)
    fun completeOfflineIntervalRetainsRuntimeAndWifiRecoversDataPlane() {
        assumeTrue(
            "Physical network matrix requires -e physicalNetworkMatrix true",
            InstrumentationRegistry.getArguments()
                .getString("physicalNetworkMatrix")
                .equals("true", ignoreCase = true),
        )
        assumeTrue("VPN consent must be granted before the matrix", VpnService.prepare(context) == null)

        val wifiInitiallyEnabled = shell("settings get global wifi_on").trim() == "1"
        val dataInitiallyEnabled = shell("settings get global mobile_data").trim() != "0"
        assumeTrue("Matrix starts from enabled Wi-Fi", wifiInitiallyEnabled)

        try {
            ContextCompat.startForegroundService(context, VeerVpnService.startIntent(context))
            assertNotNull("VPN did not reach Running", awaitRunning(15_000L))
            assertTrue("Wi-Fi never became validated", awaitTransport(NetworkCapabilities.TRANSPORT_WIFI))
            assertHealthy("Wi-Fi baseline")

            shell("svc wifi disable")
            shell("svc data disable")
            assertTrue(
                "Physical internet remained validated after Wi-Fi and data were disabled",
                awaitNoValidatedPhysicalNetwork(timeoutMs = 20_000L),
            )
            Thread.sleep(3_000L)
            assertTrue("Offline interval stopped or errored the runtime", isRunning())

            if (dataInitiallyEnabled) shell("svc data enable")
            shell("svc wifi enable")
            assertTrue(
                "Wi-Fi did not reconnect after the offline interval",
                awaitTransport(NetworkCapabilities.TRANSPORT_WIFI, timeoutMs = 45_000L),
            )
            assertTrue("Core left Running during Wi-Fi recovery", isRunning())
            assertHealthy("Wi-Fi recovery", timeoutMs = 30_000L)
        } finally {
            shell(if (dataInitiallyEnabled) "svc data enable" else "svc data disable")
            shell(if (wifiInitiallyEnabled) "svc wifi enable" else "svc wifi disable")
            ContextCompat.startForegroundService(context, VeerVpnService.stopIntent(context))
            runBlocking {
                withTimeoutOrNull(12_000L) {
                    MihomoEngine.state.first { it is EngineState.Stopped }
                }
            }
        }
    }

    private fun awaitRunning(timeoutMs: Long): EngineState.Running? = runBlocking {
        withTimeoutOrNull(timeoutMs) {
            @Suppress("UNCHECKED_CAST")
            MihomoEngine.state.first { it is EngineState.Running } as EngineState.Running
        }
    }

    private fun isRunning(): Boolean = MihomoEngine.state.value is EngineState.Running

    private fun awaitTransport(transport: Int, timeoutMs: Long = 30_000L): Boolean =
        awaitCondition(timeoutMs) { hasValidatedPhysicalTransport(transport) }

    private fun awaitNoValidatedPhysicalNetwork(timeoutMs: Long): Boolean =
        awaitCondition(timeoutMs) {
            physicalCapabilities().none {
                it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            }
        }

    private fun awaitCondition(timeoutMs: Long, predicate: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return true
            Thread.sleep(250L)
        }
        return predicate()
    }

    private fun hasValidatedPhysicalTransport(transport: Int): Boolean =
        physicalCapabilities().any {
            it.hasTransport(transport) &&
                it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }

    @Suppress("DEPRECATION")
    private fun physicalCapabilities(): List<NetworkCapabilities> =
        connectivityManager.allNetworks.mapNotNull { network ->
            connectivityManager.getNetworkCapabilities(network)?.takeIf {
                it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            }
        }

    private fun assertHealthy(stage: String, timeoutMs: Long = 20_000L) {
        val deadline = System.currentTimeMillis() + timeoutMs
        var lastSummary = "diagnostic did not run"
        do {
            val report = runBlocking { NetworkDiagnosticExecutor(context).diagnose("example.com") }
            lastSummary = report.summary
            if (report.category == DiagnosticCategory.HEALTHY) return
            Thread.sleep(750L)
        } while (System.currentTimeMillis() < deadline)
        throw AssertionError("$stage data plane did not become healthy: $lastSummary")
    }

    private fun shell(command: String): String {
        val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
        return ParcelFileDescriptor.AutoCloseInputStream(descriptor)
            .bufferedReader()
            .use { it.readText() }
    }
}
