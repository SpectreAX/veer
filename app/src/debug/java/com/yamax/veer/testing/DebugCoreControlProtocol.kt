package com.yamax.veer.testing

import android.net.Uri

internal object DebugCoreControlProtocol {
    const val AUTHORITY = "com.yamax.veer.debug.core"
    val URI: Uri get() = Uri.parse("content://$AUTHORITY/control")

    const val METHOD_NATIVE = "native"
    const val METHOD_COUNTERS = "counters"
    const val METHOD_GOROUTINES = "goroutines"
    const val METHOD_FIRE_ALL_NETWORKS_LOST = "fire_all_networks_lost"
    const val METHOD_ARM_TEARDOWN_CONNECTIVITY_PROBE = "arm_teardown_connectivity_probe"
    const val METHOD_TEARDOWN_CONNECTIVITY_PROBE_STATUS = "teardown_connectivity_probe_status"
    const val METHOD_SET_WATCHDOG_TIMINGS = "set_watchdog_timings"
    const val METHOD_SET_STOP_TIMEOUT = "set_stop_timeout"
    const val METHOD_RESET_TIMINGS = "reset_timings"
    const val METHOD_CONFIGURE_EXHAUSTED_RECOVERY = "configure_exhausted_recovery"
    const val METHOD_RECOVERY_STATUS = "recovery_status"

    const val KEY_NATIVE_METHOD = "native_method"
    const val KEY_NATIVE_ARGUMENTS = "native_arguments"
    const val KEY_START_CALL_COUNT = "start_call_count"
    const val KEY_STOP_CALL_COUNT = "stop_call_count"
    const val KEY_INCLUDE_STACKS = "include_stacks"
    const val KEY_GOROUTINE_COUNT = "goroutine_count"
    const val KEY_GOROUTINE_TIMESTAMP = "goroutine_timestamp"
    const val KEY_GOROUTINE_STACKS = "goroutine_stacks"
    const val KEY_INITIAL_DELAY_MS = "initial_delay_ms"
    const val KEY_INTERVAL_MS = "interval_ms"
    const val KEY_TIMEOUT_MS = "timeout_ms"
    const val KEY_RECOVERY_EXHAUSTED = "recovery_exhausted"
    const val KEY_TEARDOWN_CONNECTIVITY_PROBE_FIRED = "teardown_connectivity_probe_fired"
}
