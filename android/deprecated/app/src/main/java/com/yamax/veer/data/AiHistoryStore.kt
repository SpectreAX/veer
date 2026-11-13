package com.yamax.veer.data

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

@Serializable
internal enum class AiHistorySource {
    LOCAL,
    LLM,
    SYSTEM,
}

@Serializable
internal enum class AiHistoryStatus {
    SUCCESS,
    FAILURE,
}

@Serializable
internal data class AiHistoryRuleStore(
    val enabled: List<String>,
    val disabled: List<String>,
)

@Serializable
internal data class AiHistorySelectorChange(
    val group: String,
    val previous: String?,
    val selected: String,
)

@Serializable
internal data class AiHistoryMutation(
    val rulesBefore: AiHistoryRuleStore? = null,
    val rulesAfter: AiHistoryRuleStore? = null,
    val selectors: List<AiHistorySelectorChange> = emptyList(),
) {
    val isReversible: Boolean
        get() = (rulesBefore != null && rulesAfter != null) ||
            selectors.any { it.previous != null }

    internal fun stateConflict(
        currentRules: AiHistoryRuleStore?,
        currentSelectors: Map<String, String>,
    ): String? {
        if (rulesAfter != null && currentRules != rulesAfter) {
            return "AI 规则已被后续操作修改"
        }
        selectors.forEach { change ->
            if (currentSelectors[change.group] != change.selected) {
                return "策略组 ${change.group} 已被后续操作修改"
            }
        }
        return null
    }
}

@Serializable
internal data class AiHistoryEntry(
    val id: String,
    val profileId: String,
    val prompt: String,
    val source: AiHistorySource,
    val status: AiHistoryStatus,
    val timestampMs: Long,
    val summary: String,
    val generatedRules: List<String> = emptyList(),
    val mutation: AiHistoryMutation? = null,
    val undoneAtMs: Long? = null,
) {
    val canUndo: Boolean
        get() = status == AiHistoryStatus.SUCCESS &&
            undoneAtMs == null &&
            mutation?.isReversible == true
}

/**
 * Bounded, app-private AI command history. The store never receives or writes
 * API credentials; only the user's command and committed execution summary are
 * persisted. Entries are newest-first and scoped with the active profile ID.
 */
internal class AiHistoryStore private constructor(
    private val file: File,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = true
    }

    @Synchronized
    fun entries(): List<AiHistoryEntry> = readEntries()

    @Synchronized
    fun find(id: String): AiHistoryEntry? = readEntries().firstOrNull { it.id == id }

    @Synchronized
    fun append(
        profileId: String,
        prompt: String,
        source: AiHistorySource,
        status: AiHistoryStatus,
        summary: String,
        generatedRules: List<String> = emptyList(),
        mutation: AiHistoryMutation? = null,
        timestampMs: Long = System.currentTimeMillis(),
        id: String = UUID.randomUUID().toString(),
    ): AiHistoryEntry {
        val entry = AiHistoryEntry(
            id = id,
            profileId = profileId,
            prompt = prompt.trim().take(MAX_PROMPT_LENGTH),
            source = source,
            status = status,
            timestampMs = timestampMs,
            summary = summary.trim().take(MAX_SUMMARY_LENGTH),
            generatedRules = generatedRules.map { it.take(MAX_RULE_LENGTH) }.take(MAX_RULES),
            mutation = mutation,
        )
        writeEntries((listOf(entry) + readEntries()).distinctBy(AiHistoryEntry::id).take(MAX_ENTRIES))
        return entry
    }

    @Synchronized
    fun markUndone(id: String, timestampMs: Long = System.currentTimeMillis()): Boolean {
        val before = readEntries()
        var changed = false
        val after = before.map { entry ->
            if (entry.id == id && entry.canUndo) {
                changed = true
                entry.copy(undoneAtMs = timestampMs)
            } else {
                entry
            }
        }
        if (changed) writeEntries(after)
        return changed
    }

    private fun readEntries(): List<AiHistoryEntry> {
        if (!file.isFile) return emptyList()
        return runCatching {
            json.decodeFromString<List<AiHistoryEntry>>(file.readText())
                .sortedByDescending(AiHistoryEntry::timestampMs)
                .take(MAX_ENTRIES)
        }.getOrDefault(emptyList())
    }

    private fun writeEntries(entries: List<AiHistoryEntry>) {
        file.parentFile?.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.writeText(json.encodeToString(entries))
        runCatching {
            Files.move(
                temp.toPath(),
                file.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        }.getOrElse {
            Files.move(temp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    companion object {
        private const val MAX_ENTRIES = 100
        private const val MAX_PROMPT_LENGTH = 2_000
        private const val MAX_SUMMARY_LENGTH = 4_000
        private const val MAX_RULE_LENGTH = 1_024
        private const val MAX_RULES = 16

        @Volatile private var instance: AiHistoryStore? = null

        fun get(context: Context): AiHistoryStore = instance ?: synchronized(this) {
            instance ?: AiHistoryStore(
                File(File(context.applicationContext.filesDir, "ai"), "history.json"),
            ).also { instance = it }
        }

        internal fun forFile(file: File): AiHistoryStore = AiHistoryStore(file)
    }
}

internal fun AiRuleStore.toHistoryRuleStore(): AiHistoryRuleStore =
    AiHistoryRuleStore(enabled = enabled, disabled = disabled)

internal fun AiHistoryRuleStore.toAiRuleStore(): AiRuleStore =
    AiRuleStore(enabled = enabled, disabled = disabled)
