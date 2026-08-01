package com.yamax.veer.testing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.yamax.veer.core_ai.AiController
import com.yamax.veer.core_ai.LlmClient
import com.yamax.veer.core_diagnostics.NetworkDiagnosticExecutor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** Debug-only ADB hook for repeatable end-to-end AI tests without restarting
 * the app process (and therefore without tearing down the live VPN service). */
class DebugAiCommandReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val prompt = intent.getStringExtra(EXTRA_PROMPT)?.trim().orEmpty()
        val planJson = intent.getStringExtra(EXTRA_PLAN_JSON)?.trim().orEmpty()
        val undoHistoryId = intent.getStringExtra(EXTRA_UNDO_HISTORY_ID)?.trim().orEmpty()
        val failCheckpoint = intent.getStringExtra(EXTRA_FAIL_CHECKPOINT)?.trim().orEmpty()
        val diagnosticFault = intent.getStringExtra(EXTRA_DIAGNOSTIC_FAULT)?.trim().orEmpty()
        if (prompt.isEmpty() && planJson.isEmpty() && undoHistoryId.isEmpty()) return
        val pending = goAsync()
        scope.launch {
            val summary = runCatching {
                val controller = AiController(
                    context = context.applicationContext,
                    commitCheckpointForTesting = { checkpoint ->
                        if (checkpoint == failCheckpoint) {
                            error("injected AI plan commit failure at $checkpoint")
                        }
                    },
                    diagnosticExecutor = NetworkDiagnosticExecutor(
                        context.applicationContext,
                        probeOutcomeForTesting = { url ->
                            when {
                                diagnosticFault == "proxy_exit" &&
                                    url == "https://www.gstatic.com/generate_204" -> false
                                diagnosticFault == "target_site" &&
                                    url != "https://www.gstatic.com/generate_204" -> false
                                else -> null
                            }
                        },
                    ),
                )
                if (undoHistoryId.isNotEmpty()) {
                    when (val outcome = controller.undoHistory(undoHistoryId)) {
                        is AiController.HistoryActionOutcome.Success ->
                            "undo success message=${outcome.message}"
                        is AiController.HistoryActionOutcome.Failure ->
                            "undo failure message=${outcome.message}"
                    }
                } else {
                    val outcome = if (planJson.isNotEmpty()) {
                        controller.executeResolvedPlan(LlmClient("debug").decodePlan(planJson))
                    } else {
                        controller.handle(prompt)
                    }
                    when (outcome) {
                        is AiController.Outcome.Success -> buildString {
                            append("success schema=${outcome.plan.schemaVersion}")
                            append(" source=${if (outcome.resolvedLocally) "local" else "llm"}")
                            append(" operations=${outcome.stepResults.size}")
                            outcome.stepResults.forEachIndexed { index, step ->
                                append(" step${index + 1}=${step.intent.action}")
                                append(":${step.intent.target}")
                                append(":${step.intent.proxyGroup}")
                                if (step.details.isNotEmpty()) {
                                    append(":checks[${step.details.joinToString("|")}]")
                                }
                            }
                            append(" result=${outcome.ruleLine ?: "-"}")
                            append(" reply=${outcome.reply}")
                        }
                        is AiController.Outcome.Failure ->
                            "failure completed=${outcome.completed.size} message=${outcome.message}"
                    }
                }
            }.getOrElse { error -> "failure message=${error.message ?: error}" }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_LAST_RESULT, summary)
                .apply()
            Log.i(TAG, summary)
            pending.finish()
        }
    }

    private companion object {
        const val EXTRA_PROMPT = "prompt"
        const val EXTRA_PLAN_JSON = "plan_json"
        const val EXTRA_UNDO_HISTORY_ID = "undo_history_id"
        const val EXTRA_FAIL_CHECKPOINT = "fail_checkpoint"
        const val EXTRA_DIAGNOSTIC_FAULT = "diagnostic_fault"
        const val PREFS = "debug_ai_results"
        const val KEY_LAST_RESULT = "last_result"
        const val TAG = "VeerDebugAi"
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }
}
