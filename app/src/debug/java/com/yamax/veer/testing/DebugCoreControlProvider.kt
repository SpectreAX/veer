package com.yamax.veer.testing

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import com.yamax.veer.core_mihomo.VeerVpnService
import veercore.Veercore
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Debug-only, same-UID control endpoint hosted in `:veercore`.
 *
 * Instrumentation runs in the main process after production process isolation,
 * so native fault hooks and service timing overrides must cross a process
 * boundary to affect the actual runtime under test.
 */
class DebugCoreControlProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle = when (method) {
        DebugCoreControlProtocol.METHOD_NATIVE -> {
            invokeWhitelistedNative(
                name = extras?.getString(DebugCoreControlProtocol.KEY_NATIVE_METHOD).orEmpty(),
                encodedArguments = extras
                    ?.getStringArrayList(DebugCoreControlProtocol.KEY_NATIVE_ARGUMENTS)
                    .orEmpty(),
            )
            Bundle.EMPTY
        }
        DebugCoreControlProtocol.METHOD_COUNTERS -> Bundle().apply {
            putInt(
                DebugCoreControlProtocol.KEY_START_CALL_COUNT,
                nativeLong("getStartCallCount").toInt(),
            )
            putInt(
                DebugCoreControlProtocol.KEY_STOP_CALL_COUNT,
                nativeLong("getStopCallCount").toInt(),
            )
        }
        DebugCoreControlProtocol.METHOD_GOROUTINES -> {
            val snapshot = GoroutineInventory.take(
                includeStacks = extras?.getBoolean(
                    DebugCoreControlProtocol.KEY_INCLUDE_STACKS,
                ) == true,
            )
            Bundle().apply {
                putInt(DebugCoreControlProtocol.KEY_GOROUTINE_COUNT, snapshot.count)
                putLong(DebugCoreControlProtocol.KEY_GOROUTINE_TIMESTAMP, snapshot.timestampMs)
                putString(
                    DebugCoreControlProtocol.KEY_GOROUTINE_STACKS,
                    snapshot.stacks.take(MAX_REMOTE_STACK_CHARS),
                )
            }
        }
        DebugCoreControlProtocol.METHOD_FIRE_ALL_NETWORKS_LOST -> {
            VeerVpnService.debugAllNetworksLostCallback?.invoke()
            Bundle.EMPTY
        }
        DebugCoreControlProtocol.METHOD_ARM_TEARDOWN_CONNECTIVITY_PROBE -> {
            teardownConnectivityProbeFired.set(false)
            VeerVpnService.testBeforeConnectivityMonitorStop = {
                val callback = VeerVpnService.debugAllNetworksLostCallback
                callback?.invoke()
                teardownConnectivityProbeFired.set(callback != null)
            }
            Bundle.EMPTY
        }
        DebugCoreControlProtocol.METHOD_TEARDOWN_CONNECTIVITY_PROBE_STATUS -> Bundle().apply {
            putBoolean(
                DebugCoreControlProtocol.KEY_TEARDOWN_CONNECTIVITY_PROBE_FIRED,
                teardownConnectivityProbeFired.get(),
            )
        }
        DebugCoreControlProtocol.METHOD_SET_WATCHDOG_TIMINGS -> {
            VeerVpnService.testWatchdogInitialDelayMs = extras?.getLong(
                DebugCoreControlProtocol.KEY_INITIAL_DELAY_MS,
                -1L,
            ) ?: -1L
            VeerVpnService.testWatchdogIntervalMs = extras?.getLong(
                DebugCoreControlProtocol.KEY_INTERVAL_MS,
                -1L,
            ) ?: -1L
            Bundle.EMPTY
        }
        DebugCoreControlProtocol.METHOD_SET_STOP_TIMEOUT -> {
            VeerVpnService.testStopTimeoutMs = extras?.getLong(
                DebugCoreControlProtocol.KEY_TIMEOUT_MS,
                -1L,
            ) ?: -1L
            Bundle.EMPTY
        }
        DebugCoreControlProtocol.METHOD_RESET_TIMINGS -> {
            resetTimings()
            Bundle.EMPTY
        }
        DebugCoreControlProtocol.METHOD_CONFIGURE_EXHAUSTED_RECOVERY -> {
            recoveryExhausted.set(false)
            VeerVpnService.testAutoRecoveryInitialDelayMs = 200L
            VeerVpnService.testAutoRecoveryIntervalMs = 300L
            VeerVpnService.testAutoRecoveryFailureThreshold = 2
            VeerVpnService.testAutoRecoveryMaxCandidates = 1
            VeerVpnService.testAutoRecoveryInternetProbe = { false }
            VeerVpnService.testAutoRecoveryExhaustedCallback = {
                recoveryExhausted.set(true)
            }
            Bundle.EMPTY
        }
        DebugCoreControlProtocol.METHOD_RECOVERY_STATUS -> Bundle().apply {
            putBoolean(
                DebugCoreControlProtocol.KEY_RECOVERY_EXHAUSTED,
                recoveryExhausted.get(),
            )
        }
        else -> Bundle.EMPTY
    }

    private fun invokeWhitelistedNative(name: String, encodedArguments: List<String>) {
        if (name !in ALLOWED_NATIVE_METHODS) return
        runCatching {
            val method = Veercore::class.java.methods.firstOrNull {
                it.name == name && it.parameterCount == encodedArguments.size
            } ?: return@runCatching
            val arguments = arrayOfNulls<Any>(method.parameterCount)
            method.parameterTypes.forEachIndexed { index, type ->
                val value = encodedArguments[index]
                arguments[index] = when (type) {
                    java.lang.Long.TYPE, java.lang.Long::class.java -> value.toLong()
                    java.lang.Integer.TYPE, java.lang.Integer::class.java -> value.toInt()
                    java.lang.Boolean.TYPE, java.lang.Boolean::class.java -> value.toBoolean()
                    else -> value
                }
            }
            method.invoke(null, *arguments)
        }
    }

    private fun nativeLong(name: String): Long = runCatching {
        (Veercore::class.java.getMethod(name).invoke(null) as? Number)?.toLong()
    }.getOrNull() ?: 0L

    private fun resetTimings() {
        recoveryExhausted.set(false)
        teardownConnectivityProbeFired.set(false)
        VeerVpnService.testWatchdogInitialDelayMs = -1L
        VeerVpnService.testWatchdogIntervalMs = -1L
        VeerVpnService.testStopTimeoutMs = -1L
        VeerVpnService.testAutoRecoveryInitialDelayMs = -1L
        VeerVpnService.testAutoRecoveryIntervalMs = -1L
        VeerVpnService.testAutoRecoveryFailureThreshold = -1
        VeerVpnService.testAutoRecoveryMaxCandidates = -1
        VeerVpnService.testAutoRecoveryInternetProbe = null
        VeerVpnService.testAutoRecoveryExhaustedCallback = null
        VeerVpnService.testBeforeConnectivityMonitorStop = null
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        private const val MAX_REMOTE_STACK_CHARS = 256_000
        private val recoveryExhausted = AtomicBoolean()
        private val teardownConnectivityProbeFired = AtomicBoolean()
        private val ALLOWED_NATIVE_METHODS = setOf(
            "setFaultHangBeforeApplyConfig",
            "releaseHangBeforeApplyConfig",
            "setFaultErrorBeforeApplyConfig",
            "setFaultPanicBeforeApplyConfig",
            "setFaultBackgroundPanic",
            "resetCallCounts",
            "setFaultHangBeforeShutdown",
            "releaseHangBeforeShutdown",
            "clearAllFaults",
        )
    }
}
