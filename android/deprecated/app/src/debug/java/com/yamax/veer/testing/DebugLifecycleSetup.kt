package com.yamax.veer.testing

import android.content.Context
import com.yamax.veer.core_mihomo.ConnectivityMonitor
import com.yamax.veer.core_mihomo.MihomoEngine

/**
 * Wires the debug-only observability infrastructure into [MihomoEngine] and
 * [ConnectivityMonitor].
 *
 * Must be called once before any lifecycle test runs (typically in @Before or
 * @BeforeClass). Idempotent — subsequent calls replace observers with the same
 * ones, which is harmless.
 *
 * Only compiled in the debug source set; the observer vars are internal and
 * null-by-default — never written in release builds.
 */
object DebugLifecycleSetup {

    fun install(context: Context? = null) {
        context?.let {
            FaultInjector.install(it)
            GoroutineInventory.install(it)
        }
        MihomoEngine.stateObserver = { state -> PhaseTrace.record(state) }
        ConnectivityMonitor.eventObserver = { event -> ConnectivityTrace.record(event) }
    }

    fun uninstall() {
        MihomoEngine.stateObserver = null
        ConnectivityMonitor.eventObserver = null
    }
}
