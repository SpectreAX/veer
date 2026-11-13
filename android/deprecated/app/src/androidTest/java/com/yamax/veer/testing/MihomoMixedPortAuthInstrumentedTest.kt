package com.yamax.veer.testing

import android.net.VpnService
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.core_diagnostics.DiagnosticCheckStatus
import com.yamax.veer.core_diagnostics.NetworkDiagnosticExecutor
import com.yamax.veer.core_mihomo.AutoRecoveryManager
import com.yamax.veer.core_mihomo.AutoRecoveryResult
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.MihomoLocalProxy
import com.yamax.veer.core_mihomo.VeerVpnService
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import okhttp3.Request

/** Ensures the app's own proxy probes still work after mixed-port auth is required. */
@RunWith(AndroidJUnit4::class)
class MihomoMixedPortAuthInstrumentedTest {
    @Test(timeout = 60_000)
    fun authenticatedProxyCanReachDirectSite() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("VPN consent must be granted first", VpnService.prepare(context) == null)
        context.startForegroundService(VeerVpnService.startIntent(context))
        withTimeout(30_000) { MihomoEngine.state.first { it is EngineState.Running } }
        MihomoLocalProxy.clientBuilder().build().newCall(
            Request.Builder().url("https://www.baidu.com/").get().build(),
        ).execute().use { assertTrue("DIRECT site returned ${it.code}", it.isSuccessful) }
    }

    @Test(timeout = 60_000)
    fun diagnosticsAndRecoveryUseAuthenticatedProxy() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("VPN consent must be granted first", VpnService.prepare(context) == null)
        context.startForegroundService(VeerVpnService.startIntent(context))
        withTimeout(30_000) { MihomoEngine.state.first { it is EngineState.Running } }
        val report = NetworkDiagnosticExecutor(context).diagnose("www.gstatic.com")
        val internet = report.checks.first { it.id == "internet" }
        assertEquals(
            internet.detail,
            DiagnosticCheckStatus.PASS,
            internet.status,
        )
        assertEquals(AutoRecoveryResult.Healthy, AutoRecoveryManager(context).checkAndRecover())
    }
}
