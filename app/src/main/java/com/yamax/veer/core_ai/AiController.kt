package com.yamax.veer.core_ai

import android.content.Context
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.data.ApiKeyStore
import com.yamax.veer.data.ConfigManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Pipeline: user text → LLM intent → YAML rule line → ai_override.yaml →
 * Mihomo hot-reload → reply to UI.
 *
 * The API key is resolved per-call from [ApiKeyStore] so that updating the
 * key in the UI takes effect on the very next request, no restart required.
 *
 * Talks to Mihomo exclusively through [MihomoRepository] — the controller
 * host/port live there, not here.
 */
class AiController(
    private val context: Context,
    private val mihomo: MihomoRepository = MihomoRepository.get(),
    private val llmFactory: (String) -> LlmClient = { key -> LlmClient(key) },
) {

    suspend fun handle(userText: String): Outcome {
        if (userText.isBlank()) return Outcome.Failure("empty input")

        val key = ApiKeyStore.deepseekKey(context)
        if (key.isBlank()) {
            return Outcome.Failure("DEEPSEEK_API_KEY missing — paste your key in the API Key field above")
        }
        val llm = llmFactory(key)

        val groups = mihomo.proxyGroups()
        val intent = try {
            llm.resolveIntent(userText, groups)
        } catch (e: LlmException) {
            return Outcome.Failure(e.message ?: "llm error")
        }

        // Diagnostic / DNS intents don't mutate rules; we just bubble the reply
        // back so the AI layer can later plug in real diagnostics.
        if (intent.action != AiIntent.Action.ADD_RULE) {
            return Outcome.Success(
                intent = intent,
                reloadStatus = null,
                ruleLine = null,
                reply = intent.replyMessage,
            )
        }

        if (intent.matchType == AiIntent.MatchType.NONE) {
            return Outcome.Failure("intent action=add_rule but match_type=NONE — refusing to write rule")
        }

        val ruleLine = formatRule(intent)
        appendRule(ConfigManager.aiOverrideFile(context), ruleLine)

        val reload = mihomo.reloadAiProvider()
        return Outcome.Success(
            intent = intent,
            reloadStatus = reload.status,
            ruleLine = ruleLine,
            reply = intent.replyMessage,
        )
    }

    /** Builds e.g. `DOMAIN-SUFFIX,netflix.com,SG-狮城`. */
    private fun formatRule(intent: AiIntent): String =
        "${intent.matchType.ruleToken},${intent.target},${intent.proxyGroup}"

    /**
     * Appends a rule to a classical YAML rule-provider file, transparently
     * upgrading the seeded `payload: []` to a list form.
     */
    private suspend fun appendRule(file: File, rule: String) = withContext(Dispatchers.IO) {
        val current = if (file.exists()) file.readText() else "payload: []\n"
        val quoted = "'${rule.replace("'", "''")}'"
        val updated = if (EMPTY_PAYLOAD.containsMatchIn(current)) {
            EMPTY_PAYLOAD.replace(current, "payload:\n  - $quoted")
        } else {
            current.trimEnd() + "\n  - $quoted\n"
        }
        file.writeText(updated)
    }

    sealed interface Outcome {
        val message: String

        data class Success(
            val intent: AiIntent,
            val reloadStatus: Int?,
            val ruleLine: String?,
            val reply: String,
        ) : Outcome {
            override val message: String get() = reply
        }

        data class Failure(override val message: String) : Outcome
    }

    private companion object {
        val EMPTY_PAYLOAD = Regex("""payload:\s*\[\s*\]""")
    }
}
