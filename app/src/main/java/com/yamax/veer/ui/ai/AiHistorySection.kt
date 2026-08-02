package com.yamax.veer.ui.ai

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.annotation.StringRes
import com.yamax.veer.R
import com.yamax.veer.data.AiHistoryEntry
import com.yamax.veer.data.AiHistorySource
import com.yamax.veer.data.AiHistoryStatus
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal data class AiPromptTemplate(
    val id: String,
    @param:StringRes val titleRes: Int,
    @param:StringRes val promptRes: Int,
)

internal val AI_PROMPT_TEMPLATES = listOf(
    AiPromptTemplate(
        "netflix_jp",
        R.string.ai_template_netflix_jp_title,
        R.string.ai_template_netflix_jp_prompt,
    ),
    AiPromptTemplate(
        "chatgpt_us",
        R.string.ai_template_chatgpt_us_title,
        R.string.ai_template_chatgpt_us_prompt,
    ),
    AiPromptTemplate(
        "lowest_latency",
        R.string.ai_template_low_latency_title,
        R.string.ai_template_low_latency_prompt,
    ),
    AiPromptTemplate(
        "diagnose",
        R.string.ai_template_diagnose_title,
        R.string.ai_template_diagnose_prompt,
    ),
)

@Composable
internal fun AiQuickTemplateRow(
    enabled: Boolean,
    onSelect: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            stringResource(R.string.ai_templates_title),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .testTag("ai_quick_templates"),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            AI_PROMPT_TEMPLATES.forEach { template ->
                val title = stringResource(template.titleRes)
                val resolvedPrompt = stringResource(template.promptRes)
                AssistChip(
                    onClick = { onSelect(resolvedPrompt) },
                    enabled = enabled,
                    label = { Text(title) },
                    modifier = Modifier.testTag("ai_template_${template.id}"),
                )
            }
        }
    }
}

@Composable
internal fun AiHistorySection(
    entries: List<AiHistoryEntry>,
    activeProfileId: String?,
    busy: Boolean,
    onReplay: (AiHistoryEntry) -> Unit,
    onUndo: (AiHistoryEntry) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val visible = entries.take(if (expanded) 10 else 3)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("ai_history"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                stringResource(R.string.ai_history_title),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            if (entries.size > 3) {
                TextButton(onClick = { expanded = !expanded }) {
                    Text(
                        stringResource(
                            if (expanded) R.string.common_collapse else R.string.common_view_all,
                        ),
                    )
                }
            }
        }
        if (entries.isEmpty()) {
            Text(
                stringResource(R.string.ai_history_empty),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            visible.forEachIndexed { index, entry ->
                if (index > 0) HorizontalDivider()
                AiHistoryCard(
                    entry = entry,
                    isActiveProfile = entry.profileId == activeProfileId,
                    busy = busy,
                    onReplay = onReplay,
                    onUndo = onUndo,
                )
            }
        }
    }
}

@Composable
private fun AiHistoryCard(
    entry: AiHistoryEntry,
    isActiveProfile: Boolean,
    busy: Boolean,
    onReplay: (AiHistoryEntry) -> Unit,
    onUndo: (AiHistoryEntry) -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                entry.prompt,
                style = MaterialTheme.typography.titleSmall,
            )
            val source = stringResource(when (entry.source) {
                AiHistorySource.LOCAL -> R.string.ai_history_source_local
                AiHistorySource.LLM -> R.string.ai_history_source_llm
                AiHistorySource.SYSTEM -> R.string.ai_history_source_system
            })
            val result = stringResource(when {
                entry.undoneAtMs != null -> R.string.ai_history_undone
                entry.status == AiHistoryStatus.SUCCESS -> R.string.ai_history_success
                else -> R.string.ai_history_failure
            })
            Text(
                stringResource(
                    R.string.ai_history_metadata,
                    formatHistoryTime(entry.timestampMs),
                    source,
                    result,
                ),
                style = MaterialTheme.typography.labelSmall,
                color = if (entry.status == AiHistoryStatus.FAILURE) {
                    MaterialTheme.colorScheme.error
                } else {
                    MaterialTheme.colorScheme.onSurfaceVariant
                },
            )
            Text(entry.summary, style = MaterialTheme.typography.bodySmall)
            entry.generatedRules.takeIf { it.isNotEmpty() }?.let { rules ->
                Text(
                    rules.joinToString("\n"),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TextButton(
                    onClick = { onReplay(entry) },
                    enabled = !busy && isActiveProfile,
                ) {
                    Text(stringResource(R.string.ai_history_replay))
                }
                if (entry.mutation?.isReversible == true) {
                    TextButton(
                        onClick = { onUndo(entry) },
                        enabled = !busy && isActiveProfile && entry.canUndo,
                        modifier = Modifier.testTag("ai_history_undo"),
                    ) {
                        Text(
                            stringResource(
                                if (entry.undoneAtMs == null) R.string.ai_history_undo
                                else R.string.ai_history_undone,
                            ),
                        )
                    }
                }
                if (!isActiveProfile) {
                    Text(
                        stringResource(R.string.ai_history_switch_profile),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

internal fun formatHistoryTime(timestampMs: Long): String =
    SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(timestampMs))
