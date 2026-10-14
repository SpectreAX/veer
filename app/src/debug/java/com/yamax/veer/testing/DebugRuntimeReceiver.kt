package com.yamax.veer.testing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_compatibility.BackgroundRestrictionMonitor
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import com.yamax.veer.core_profile.internal.storage.ProfileStore
import com.yamax.veer.data.ConfigManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import veercore.Veercore
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Debug-only ADB hook for collecting Go goroutine stacks while a JNI lifecycle
 * call is blocked. The dump stays in app-private storage and contains no
 * configuration or credential values.
 */
class DebugRuntimeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_DUMP_GOROUTINES -> {
                val snapshot = GoroutineInventory.take(includeStacks = true)
                val output = File(context.filesDir, GOROUTINE_OUTPUT_FILE)
                output.writeText(snapshot.stacks)
                Log.i(TAG, "goroutines=${snapshot.count} dump=${output.absolutePath}")
            }
            ACTION_DUMP_ENGINE_STATE -> {
                val stateOutput = File(context.filesDir, ENGINE_STATE_OUTPUT_FILE)
                val profileOutput = File(context.filesDir, ACTIVE_PROFILE_OUTPUT_FILE)
                stateOutput.writeText(MihomoEngine.state.value.toString())
                profileOutput.writeText(ProfileManager.active.value?.profileId?.value.orEmpty())
                Log.i(
                    TAG,
                    "engineState=${MihomoEngine.state.value} " +
                        "activeProfile=${ProfileManager.active.value?.profileId?.value.orEmpty()} " +
                    "dump=${stateOutput.absolutePath}",
                )
            }
            ACTION_DUMP_BACKGROUND_RESTRICTIONS -> {
                val status = BackgroundRestrictionMonitor.snapshot(context)
                File(context.filesDir, BACKGROUND_RESTRICTION_OUTPUT_FILE).writeText(
                    buildString {
                        append("risk=${status.risk}\n")
                        append("oem=${status.oemFamily}\n")
                        append(
                            "batteryOptimizationExempt=" +
                                "${status.batteryOptimizationExempt}\n",
                        )
                        append("backgroundRestricted=${status.backgroundRestricted}\n")
                        append("standbyBucket=${status.standbyBucket}\n")
                        append("powerSaveMode=${status.powerSaveMode}\n")
                        append("needsOemReview=${status.needsOemReview}\n")
                        append("reasons=${status.reasons.joinToString(",")}\n")
                    },
                )
                Log.i(
                    TAG,
                    "background risk=${status.risk} oem=${status.oemFamily} " +
                        "reasons=${status.reasons.size}",
                )
            }
            ACTION_INJECT_START_ERROR_ONCE -> {
                Veercore::class.java
                    .getMethod(
                        "setFaultErrorOnceBeforeApplyConfig",
                        String::class.java,
                    )
                    .invoke(null, "injected one-shot startup failure")
                Log.i(TAG, "installed one-shot startup failure")
            }
            ACTION_CLEAR_FAULTS -> {
                Veercore::class.java.getMethod("clearAllFaults").invoke(null)
                Log.i(TAG, "cleared native fault injection")
            }
            ACTION_ADD_TEST_RULE -> {
                val pending = goAsync()
                scope.launch {
                    val rule = intent.getStringExtra(EXTRA_RULE)?.trim().orEmpty()
                    val changed = rule.isNotEmpty() && ConfigManager.addAiRule(context, rule)
                    val config = ConfigManager.materializeBaseConfig(context)
                    val reload = if (MihomoEngine.state.value is
                        com.yamax.veer.core_mihomo.EngineState.Running
                    ) {
                        MihomoRepository.get().reloadRules(config).success
                    } else {
                        false
                    }
                    Log.i(TAG, "test rule changed=$changed runtimeReload=$reload")
                    pending.finish()
                }
            }
            ACTION_REMOVE_TEST_RULE -> {
                val pending = goAsync()
                scope.launch {
                    val rule = intent.getStringExtra(EXTRA_RULE)?.trim().orEmpty()
                    val changed = rule.isNotEmpty() &&
                        ConfigManager.deleteAiRuleRaw(context, rule)
                    val config = ConfigManager.materializeBaseConfig(context)
                    val reload = if (MihomoEngine.state.value is
                        com.yamax.veer.core_mihomo.EngineState.Running
                    ) {
                        MihomoRepository.get().reloadRules(config).success
                    } else {
                        false
                    }
                    Log.i(TAG, "test rule removed=$changed runtimeReload=$reload")
                    pending.finish()
                }
            }
            ACTION_CONFIGURE_AUTO_RECOVERY -> {
                val mode = intent.getStringExtra(EXTRA_MODE)?.trim().orEmpty()
                when (mode) {
                    "recover" -> {
                        val calls = AtomicInteger()
                        configureAutoRecovery {
                            calls.incrementAndGet() >= 3
                        }
                    }
                    "exhaust" -> configureAutoRecovery { false }
                    "healthy" -> configureAutoRecovery { true }
                    "reset" -> resetAutoRecovery()
                    else -> {
                        Log.w(TAG, "unknown auto recovery mode=$mode")
                        return
                    }
                }
                Log.i(TAG, "auto recovery configured mode=$mode")
            }
            ACTION_VERIFY_REFRESH_FAILURE_SAFETY -> {
                val pending = goAsync()
                scope.launch {
                    val active = ProfileManager.active.value?.profileId
                    val before = active?.let {
                        ProfileStore.readGeneratedConfig(context, it)
                    }
                    val result = active?.let {
                        ProfileManager.import(
                            context = context,
                            input = ProfileInput.YamlBytes(
                                "invalid: [unterminated".toByteArray(),
                                "invalid-refresh-test.yaml",
                            ),
                            existingId = it,
                            updateActiveRuntime = false,
                            publishImportState = false,
                        )
                    }
                    val after = active?.let {
                        ProfileStore.readGeneratedConfig(context, it)
                    }
                    val safe = result is ImportResult.Failure &&
                        before != null &&
                        before == after
                    File(context.filesDir, REFRESH_FAILURE_RESULT_FILE)
                        .writeText("failed=${result is ImportResult.Failure} unchanged=$safe")
                    Log.i(TAG, "refresh failure safety failed=${result is ImportResult.Failure} unchanged=$safe")
                    pending.finish()
                }
            }
            ACTION_VERIFY_LOG_REDACTION -> {
                val fakeKey = "debug-api-key-redaction-test-1234567890"
                val fakeUrl = "https://example.invalid/private/subscription?token=fake-token"
                VeerLog.core(
                    "redaction probe Authorization: Bearer fake-bearer " +
                        "api_key=$fakeKey url=$fakeUrl",
                )
                val bundle = VeerLog.exportDebugBundle(context)
                val text = bundle.readText()
                val safe = fakeKey !in text &&
                    fakeUrl !in text &&
                    "fake-bearer" !in text &&
                    "[redacted" in text
                File(context.filesDir, LOG_REDACTION_RESULT_FILE)
                    .writeText("redacted=$safe")
                Log.i(TAG, "log redaction verified=$safe")
            }
            ACTION_START_VPN -> {
                if (VpnService.prepare(context) != null) {
                    Log.e(TAG, "benchmark start rejected: VPN permission is not granted")
                } else {
                    context.startForegroundService(VeerVpnService.startIntent(context))
                    Log.i(TAG, "benchmark start requested")
                }
            }
            ACTION_STOP_VPN -> {
                context.startForegroundService(VeerVpnService.stopIntent(context))
                Log.i(TAG, "benchmark stop requested")
            }
            ACTION_RECONNECT_VPN -> {
                context.startForegroundService(VeerVpnService.reconnectIntent(context))
                Log.i(TAG, "benchmark reconnect requested")
            }
            ACTION_KILL_CORE_PROCESS -> {
                val pid = Process.myPid()
                Log.w(TAG, "terminating Veercore process pid=$pid for recovery verification")
                Handler(Looper.getMainLooper()).post {
                    Process.killProcess(pid)
                }
            }
        }
    }

    companion object {
        const val ACTION_DUMP_GOROUTINES = "com.yamax.veer.debug.DUMP_GOROUTINES"
        const val ACTION_DUMP_ENGINE_STATE = "com.yamax.veer.debug.DUMP_ENGINE_STATE"
        const val ACTION_DUMP_BACKGROUND_RESTRICTIONS =
            "com.yamax.veer.debug.DUMP_BACKGROUND_RESTRICTIONS"
        const val ACTION_INJECT_START_ERROR_ONCE =
            "com.yamax.veer.debug.INJECT_START_ERROR_ONCE"
        const val ACTION_CLEAR_FAULTS = "com.yamax.veer.debug.CLEAR_FAULTS"
        const val ACTION_ADD_TEST_RULE = "com.yamax.veer.debug.ADD_TEST_RULE"
        const val ACTION_REMOVE_TEST_RULE = "com.yamax.veer.debug.REMOVE_TEST_RULE"
        const val ACTION_CONFIGURE_AUTO_RECOVERY =
            "com.yamax.veer.debug.CONFIGURE_AUTO_RECOVERY"
        const val ACTION_VERIFY_REFRESH_FAILURE_SAFETY =
            "com.yamax.veer.debug.VERIFY_REFRESH_FAILURE_SAFETY"
        const val ACTION_VERIFY_LOG_REDACTION =
            "com.yamax.veer.debug.VERIFY_LOG_REDACTION"
        const val ACTION_START_VPN = "com.yamax.veer.debug.START_VPN"
        const val ACTION_STOP_VPN = "com.yamax.veer.debug.STOP_VPN"
        const val ACTION_RECONNECT_VPN = "com.yamax.veer.debug.RECONNECT_VPN"
        const val ACTION_KILL_CORE_PROCESS = "com.yamax.veer.debug.KILL_CORE_PROCESS"
        const val EXTRA_RULE = "rule"
        const val EXTRA_MODE = "mode"
        const val GOROUTINE_OUTPUT_FILE = "debug_goroutines.txt"
        const val ENGINE_STATE_OUTPUT_FILE = "debug_engine_state.txt"
        const val BACKGROUND_RESTRICTION_OUTPUT_FILE =
            "debug_background_restrictions.txt"
        const val ACTIVE_PROFILE_OUTPUT_FILE = "debug_active_profile.txt"
        const val REFRESH_FAILURE_RESULT_FILE = "debug_refresh_failure_result.txt"
        const val LOG_REDACTION_RESULT_FILE = "debug_log_redaction_result.txt"
        private const val TAG = "VeerDebugRuntime"
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        private fun configureAutoRecovery(probe: () -> Boolean) {
            VeerVpnService.testAutoRecoveryInitialDelayMs = 500
            VeerVpnService.testAutoRecoveryIntervalMs = 1_000
            VeerVpnService.testAutoRecoveryFailureThreshold = 2
            VeerVpnService.testAutoRecoveryMaxCandidates = 1
            VeerVpnService.testAutoRecoveryInternetProbe = probe
        }

        private fun resetAutoRecovery() {
            VeerVpnService.testAutoRecoveryInitialDelayMs = -1
            VeerVpnService.testAutoRecoveryIntervalMs = -1
            VeerVpnService.testAutoRecoveryFailureThreshold = -1
            VeerVpnService.testAutoRecoveryMaxCandidates = -1
            VeerVpnService.testAutoRecoveryInternetProbe = null
            VeerVpnService.testAutoRecoveryExhaustedCallback = null
        }
    }
}
