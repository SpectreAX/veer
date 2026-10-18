package com.yamax.veer.core_ai

import android.content.Context
import com.yamax.veer.core_diagnostics.NetworkDiagnosticExecutor
import com.yamax.veer.core_mihomo.MihomoRepository
import com.yamax.veer.core_profile.SubscriptionMetadata
import com.yamax.veer.data.AiRuleStore
import com.yamax.veer.data.AiHistoryMutation
import com.yamax.veer.data.AiHistorySelectorChange
import com.yamax.veer.data.AiHistorySource
import com.yamax.veer.data.AiHistoryStatus
import com.yamax.veer.data.AiHistoryStore
import com.yamax.veer.data.ApiKeyStore
import com.yamax.veer.data.ConfigManager
import com.yamax.veer.data.toAiRuleStore
import com.yamax.veer.data.toHistoryRuleStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Pipeline: user text → LLM intent → persistent rule → merged base.yaml →
 * Mihomo full-config hot-reload → reply to UI.
 *
 * The API key is resolved per-call from [ApiKeyStore] so that updating the
 * key in the UI takes effect on the very next request, no restart required.
 *
 * Talks to Mihomo exclusively through [MihomoRepository] — the controller
 * host/port live there, not here.
 */
class AiController internal constructor(
    private val context: Context,
    private val mihomo: MihomoRepository = MihomoRepository.get(),
    private val llmFactory: (String) -> LlmClient = { key -> LlmClient(key) },
    private val commitCheckpointForTesting: (String) -> Unit = {},
    private val diagnosticExecutor: NetworkDiagnosticExecutor =
        NetworkDiagnosticExecutor(context, mihomo),
    private val injectedHistoryStore: AiHistoryStore? = null,
) {
    private val executionMutex = Mutex()

    suspend fun handle(userText: String): Outcome {
        if (userText.isBlank()) return Outcome.Failure("empty input")

        val routingSnapshot = mihomo.routingSnapshot()
        val localPlan = LocalPlanResolver.resolve(
            userText = userText,
            snapshot = routingSnapshot,
            preferredSelector = ConfigManager.runtimeDefaultPolicy(context),
        )
        val unavailableRequestedRegion = if (localPlan == null) {
            LocalPlanResolver.requestedRoutingRegionCodes(userText)
                .firstOrNull { region ->
                    routingSnapshot.proxies.values.none { proxy ->
                        proxy.members.isEmpty() &&
                            !SubscriptionMetadata.isLikelyMetadataName(proxy.name) &&
                            proxy.regionCode == region &&
                            proxy.alive != false &&
                            proxy.delayMs != 65535
                    }
                }
        } else {
            null
        }
        if (unavailableRequestedRegion != null) {
            return recordOutcome(
                userText,
                AiHistorySource.SYSTEM,
                Outcome.Failure(
                    "未找到可用的${LocalPlanResolver.regionLabel(unavailableRequestedRegion)}节点；计划未执行",
                ),
            )
        }
        val plan = localPlan ?: run {
            val key = ApiKeyStore.deepseekKey(context)
            if (key.isBlank()) {
                return recordOutcome(
                    userText,
                    AiHistorySource.SYSTEM,
                    Outcome.Failure("该指令需要 AI 解析，但 DEEPSEEK_API_KEY 尚未配置"),
                )
            }
            val llm = llmFactory(key)
            try {
                llm.resolvePlan(userText, routingSnapshot)
            } catch (e: LlmException) {
                return recordOutcome(
                    userText,
                    AiHistorySource.LLM,
                    Outcome.Failure(e.message ?: "llm error"),
                )
            }
        }

        var mutation: AiHistoryMutation? = null
        val outcome = executionMutex.withLock {
            executeAtomicPlan(
                plan = plan,
                resolvedLocally = localPlan != null,
                onCommitted = { mutation = it },
            )
        }
        return recordOutcome(
            prompt = userText,
            source = if (localPlan != null) AiHistorySource.LOCAL else AiHistorySource.LLM,
            outcome = outcome,
            mutation = mutation,
        )
    }

    internal suspend fun executeResolvedPlan(
        plan: AiPlan,
        resolvedLocally: Boolean = false,
    ): Outcome = executionMutex.withLock {
        executeAtomicPlan(plan, resolvedLocally)
    }

    private suspend fun executeAtomicPlan(
        plan: AiPlan,
        resolvedLocally: Boolean,
        onCommitted: (AiHistoryMutation?) -> Unit = {},
    ): Outcome {
        if (plan.schemaVersion != AiPlan.CURRENT_SCHEMA_VERSION) {
            return Outcome.Failure(
                "不支持 AI 计划版本 ${plan.schemaVersion}；计划未执行",
            )
        }
        if (plan.operations.isEmpty() || plan.operations.size > AiPlan.MAX_OPERATIONS) {
            return Outcome.Failure(
                "AI 计划必须包含 1-${AiPlan.MAX_OPERATIONS} 项操作；计划未执行",
            )
        }
        if (
            plan.operations.any { it.action == AiIntent.Action.CLARIFY } &&
            plan.operations.size != 1
        ) {
            return Outcome.Failure("澄清请求不能与配置修改混在同一计划中；计划未执行")
        }

        val snapshot = mihomo.routingSnapshot()
        val routingTargets = (snapshot.proxies.keys +
            listOf("DIRECT", "REJECT", "REJECT-DROP", "PASS")).distinct()
        val seenRuleMatchers = mutableSetOf<String>()
        val seenSelectorGroups = mutableSetOf<String>()
        val prepared = mutableListOf<PreparedOperation>()

        for ((index, intent) in plan.operations.withIndex()) {
            val operation = try {
                when (intent.action) {
                    AiIntent.Action.ADD_RULE -> {
                        requirePlan(intent.matchType != AiIntent.MatchType.NONE) {
                            "action=add_rule 不能使用 match_type=NONE"
                        }
                        val normalizedIntent = normalizeGeositeIntent(intent)
                        val effectiveIntent = resolveAvailableRulePolicy(normalizedIntent, snapshot)
                            ?: throw PlanValidationException(
                                "${normalizedIntent.proxyGroup} 当前不可用，且没有同地区可用替代节点",
                            )
                        requirePlan(isSafeRule(effectiveIntent, routingTargets)) {
                            "规则包含不可用策略或不安全目标"
                        }
                        val ruleLine = formatRule(effectiveIntent)
                        val matcher = ConfigManager.parseAiRule(ruleLine)?.matcher
                            ?: throw PlanValidationException("规则格式无效")
                        requirePlan(seenRuleMatchers.add(matcher)) {
                            "同一计划不能重复修改规则 $matcher"
                        }
                        PreparedOperation.Rule(effectiveIntent, ruleLine)
                    }
                    AiIntent.Action.SWITCH_PROXY -> {
                        requirePlan(intent.matchType == AiIntent.MatchType.NONE) {
                            "action=switch_proxy 必须使用 match_type=NONE"
                        }
                        val group = snapshot.proxies[intent.target]
                            ?.takeIf { it.type == "Selector" }
                            ?: throw PlanValidationException("目标不是可用的 Selector 策略组")
                        requirePlan(seenSelectorGroups.add(group.name)) {
                            "同一计划不能重复切换策略组 ${group.name}"
                        }
                        val selected = when (intent.selectionMode) {
                            AiIntent.SelectionMode.LOWEST_LATENCY ->
                                mihomo.lowestLatencyCandidate(group.name, snapshot)
                                    ?: throw PlanValidationException("没有可测速的低延迟替换节点")
                            AiIntent.SelectionMode.SPECIFIED -> {
                                requirePlan(intent.proxyGroup in group.members) {
                                    "指定节点不属于策略组 ${group.name}"
                                }
                                snapshot.proxies[intent.proxyGroup]
                                    ?: throw PlanValidationException("指定节点不存在")
                            }
                            AiIntent.SelectionMode.NONE ->
                                throw PlanValidationException("切换代理缺少 selection_mode")
                        }
                        requirePlan(!snapshot.isKnownUnavailable(selected.name)) {
                            "${selected.name} 当前不可用"
                        }
                        PreparedOperation.Switch(
                            intent = intent,
                            group = group.name,
                            previous = group.now,
                            selected = selected,
                        )
                    }
                    AiIntent.Action.DNS_CHANGE ->
                        throw PlanValidationException(
                            "AI 暂不支持直接修改 DNS，请在“自定义 DNS”页面操作",
                        )
                    AiIntent.Action.DIAGNOSE -> {
                        requirePlan(intent.matchType == AiIntent.MatchType.NONE) {
                            "action=diagnose 必须使用 match_type=NONE"
                        }
                        PreparedOperation.NoMutation(intent)
                    }
                    AiIntent.Action.CLARIFY -> {
                        requirePlan(intent.matchType == AiIntent.MatchType.NONE) {
                            "action=clarify 必须使用 match_type=NONE"
                        }
                        PreparedOperation.NoMutation(intent)
                    }
                }
            } catch (e: PlanValidationException) {
                return Outcome.Failure(
                    "第 ${index + 1}/${plan.operations.size} 项预验证失败：${e.message}；计划未执行",
                )
            }
            prepared += operation
        }

        val ruleOperations = prepared.filterIsInstance<PreparedOperation.Rule>()
        // Diagnosis, clarification and selector-only plans must not touch the
        // profile filesystem or require bundled configuration assets.
        val originalStore = if (ruleOperations.isEmpty()) {
            AiRuleStore()
        } else {
            ConfigManager.activeAiRuleStore(context)
        }
        val (updatedStore, ruleChanges) = ConfigManager.upsertAiRules(
            originalStore,
            ruleOperations.map { it.ruleLine },
        )
        val ruleStoreChanged = updatedStore != originalStore
        val appliedSwitches = mutableListOf<PreparedOperation.Switch>()
        var reloadStatus: Int? = null

        try {
            if (ruleStoreChanged) {
                ConfigManager.replaceActiveAiRuleStore(context, updatedStore)
                val runtimeConfig = ConfigManager.materializeBaseConfig(context)
                val reload = mihomo.reloadRules(runtimeConfig)
                if (!reload.success) {
                    throw PlanCommitException("Mihomo 规则重载失败：${reload.message}")
                }
                reloadStatus = reload.status
                commitCheckpointForTesting(CHECKPOINT_AFTER_RULE_RELOAD)
            }

            prepared.filterIsInstance<PreparedOperation.Switch>().forEach { operation ->
                if (operation.selected.name != operation.previous) {
                    if (!mihomo.selectProxy(operation.group, operation.selected.name)) {
                        throw PlanCommitException(
                            "代理切换失败：${operation.group} → ${operation.selected.name}",
                        )
                    }
                    appliedSwitches += operation
                    commitCheckpointForTesting(CHECKPOINT_AFTER_PROXY_SWITCH)
                }
            }
        } catch (e: Exception) {
            val rollbackErrors = mutableListOf<String>()
            appliedSwitches.asReversed().forEach { operation ->
                val previous = operation.previous
                if (previous != null && !mihomo.selectProxy(operation.group, previous)) {
                    rollbackErrors += "无法恢复 ${operation.group} → $previous"
                }
            }
            if (ruleStoreChanged) {
                runCatching {
                    ConfigManager.replaceActiveAiRuleStore(context, originalStore)
                    val restoredConfig = ConfigManager.materializeBaseConfig(context)
                    val restored = mihomo.reloadRules(restoredConfig)
                    check(restored.success) { restored.message }
                }.onFailure { rollbackErrors += "无法恢复规则：${it.message}" }
            }
            val rollback = if (rollbackErrors.isEmpty()) {
                "所有修改已回滚"
            } else {
                "回滚不完整：${rollbackErrors.joinToString("；")}"
            }
            return Outcome.Failure("计划提交失败：${e.message}；$rollback")
        }

        val connectionRefresh = if (ruleOperations.isNotEmpty()) {
            // Refresh even when the exact rule already exists. Repeating a
            // command such as "ChatGPT go US" is also an explicit request to
            // recover sessions that are still pinned to the previous chain.
            refreshAffectedConnections(ruleOperations.map { it.intent })
        } else {
            ConnectionRefreshSummary.NONE
        }

        var ruleIndex = 0
        val results = prepared.map { operation ->
            when (operation) {
                is PreparedOperation.Rule -> {
                    val changed = ruleChanges[ruleIndex++]
                    StepResult(
                        intent = operation.intent,
                        reloadStatus = reloadStatus.takeIf { changed },
                        ruleLine = operation.ruleLine,
                        reply = ruleResultReply(operation.intent, changed),
                    )
                }
                is PreparedOperation.Switch -> {
                    val changed = operation.selected.name != operation.previous
                    val delay = operation.selected.delayMs?.let { "（${it} ms）" }.orEmpty()
                    StepResult(
                        intent = operation.intent,
                        reloadStatus = 204.takeIf { changed },
                        ruleLine = "SELECT,${operation.group},${operation.selected.name}",
                        reply = if (changed) {
                            "已将 ${operation.group} 从 ${operation.previous ?: "未知节点"}" +
                                " 切换到 ${operation.selected.name}$delay。"
                        } else {
                            "${operation.group} 已在使用 ${operation.selected.name}。"
                        },
                    )
                }
                is PreparedOperation.NoMutation -> {
                    if (operation.intent.action == AiIntent.Action.DIAGNOSE) {
                        val report = diagnosticExecutor.diagnose(operation.intent.target)
                        StepResult(
                            intent = operation.intent,
                            reloadStatus = null,
                            ruleLine = "DIAGNOSE,${report.category}",
                            reply = report.summary,
                            details = report.checks.map {
                                "${it.label}=${it.status}:${it.detail}"
                            },
                        )
                    } else {
                        StepResult(
                            intent = operation.intent,
                            reloadStatus = null,
                            ruleLine = null,
                            reply = operation.intent.replyMessage,
                        )
                    }
                }
            }
        }
        // The model's summary describes its proposed plan, not necessarily
        // the effective plan after canonicalization or availability fallback.
        // Build user feedback only from committed step results so the shown
        // exit direction always matches the actual rule or selector state.
        val reply = buildString {
            append(results.joinToString(" ") { it.reply })
            connectionRefresh.userMessage?.let { append(" ").append(it) }
        }
        val mutation = AiHistoryMutation(
            rulesBefore = originalStore.toHistoryRuleStore().takeIf { ruleStoreChanged },
            rulesAfter = updatedStore.toHistoryRuleStore().takeIf { ruleStoreChanged },
            selectors = prepared.filterIsInstance<PreparedOperation.Switch>()
                .filter { it.selected.name != it.previous }
                .map { operation ->
                    AiHistorySelectorChange(
                        group = operation.group,
                        previous = operation.previous,
                        selected = operation.selected.name,
                    )
                },
        ).takeIf(AiHistoryMutation::isReversible)
        onCommitted(mutation)
        return Outcome.Success(
            intent = results.first().intent,
            reloadStatus = results.lastOrNull { it.reloadStatus != null }?.reloadStatus,
            ruleLine = results.mapNotNull { it.ruleLine }.joinToString("\n").ifEmpty { null },
            reply = reply,
            plan = plan,
            stepResults = results,
            resolvedLocally = resolvedLocally,
        )
    }

    /** Safely reverts one still-current successful history entry. */
    suspend fun undoHistory(entryId: String): HistoryActionOutcome = executionMutex.withLock {
        val store = historyStore()
            ?: return@withLock HistoryActionOutcome.Failure("AI 历史存储不可用")
        val entry = withContext(Dispatchers.IO) { store.find(entryId) }
            ?: return@withLock HistoryActionOutcome.Failure("未找到这条 AI 历史")
        if (!entry.canUndo) {
            return@withLock HistoryActionOutcome.Failure("这条操作不可撤销或已经撤销")
        }
        val activeProfileId = ConfigManager.activeProfileId()
        if (activeProfileId != entry.profileId) {
            return@withLock HistoryActionOutcome.Failure("只能在原配置处于激活状态时撤销")
        }
        val mutation = entry.mutation
            ?: return@withLock HistoryActionOutcome.Failure("这条操作没有可恢复的状态")
        val currentRules = mutation.rulesAfter?.let {
            withContext(Dispatchers.IO) {
                ConfigManager.activeAiRuleStore(context).toHistoryRuleStore()
            }
        }
        val currentSelectors = if (mutation.selectors.isEmpty()) {
            emptyMap()
        } else {
            mihomo.proxySelections()
        }
        mutation.stateConflict(currentRules, currentSelectors)?.let { conflict ->
            return@withLock HistoryActionOutcome.Failure("无法安全撤销：$conflict")
        }

        var rulesRestored = false
        val selectorsRestored = mutableListOf<AiHistorySelectorChange>()
        try {
            mutation.rulesBefore?.let { before ->
                ConfigManager.replaceActiveAiRuleStore(context, before.toAiRuleStore())
                val runtimeConfig = ConfigManager.materializeBaseConfig(context)
                val reload = mihomo.reloadRules(runtimeConfig)
                if (!reload.success) {
                    throw HistoryUndoException("规则恢复失败：${reload.message}")
                }
                rulesRestored = true
            }
            mutation.selectors.asReversed().forEach { change ->
                val previous = change.previous
                    ?: throw HistoryUndoException("缺少 ${change.group} 的原节点记录")
                if (!mihomo.selectProxy(change.group, previous)) {
                    throw HistoryUndoException("无法恢复 ${change.group} → $previous")
                }
                selectorsRestored += change
            }
        } catch (error: Exception) {
            selectorsRestored.asReversed().forEach { change ->
                mihomo.selectProxy(change.group, change.selected)
            }
            if (rulesRestored) {
                mutation.rulesAfter?.let { after ->
                    runCatching {
                        ConfigManager.replaceActiveAiRuleStore(context, after.toAiRuleStore())
                        mihomo.reloadRules(ConfigManager.materializeBaseConfig(context))
                    }
                }
            }
            return@withLock HistoryActionOutcome.Failure(
                "撤销失败：${error.message}；已尝试恢复撤销前状态",
            )
        }

        refreshAfterUndo(entry.generatedRules, mutation.selectors.map { it.group })
        withContext(Dispatchers.IO) { store.markUndone(entry.id) }
        HistoryActionOutcome.Success("已撤销“${entry.prompt}”产生的配置修改。")
    }

    private suspend fun recordOutcome(
        prompt: String,
        source: AiHistorySource,
        outcome: Outcome,
        mutation: AiHistoryMutation? = null,
    ): Outcome {
        val store = historyStore() ?: return outcome
        withContext(Dispatchers.IO) {
            runCatching {
                store.append(
                    profileId = ConfigManager.activeProfileId() ?: DEFAULT_HISTORY_SCOPE,
                    prompt = prompt,
                    source = source,
                    status = if (outcome is Outcome.Success) {
                        AiHistoryStatus.SUCCESS
                    } else {
                        AiHistoryStatus.FAILURE
                    },
                    summary = outcome.message,
                    generatedRules = (outcome as? Outcome.Success)
                        ?.stepResults
                        .orEmpty()
                        .mapNotNull(StepResult::ruleLine),
                    mutation = mutation,
                )
            }
        }
        return outcome
    }

    private fun historyStore(): AiHistoryStore? = injectedHistoryStore ?: runCatching {
        AiHistoryStore.get(context)
    }.getOrNull()

    private suspend fun refreshAfterUndo(ruleLines: List<String>, selectorGroups: List<String>) {
        val ruleIntents = ruleLines.mapNotNull(::historyRuleIntent)
        val connections = mihomo.getConnectionDetails().getOrNull() ?: return
        connections.filter { connection ->
            ruleIntents.any { AiConnectionRefreshPolicy.shouldClose(it, connection) } ||
                selectorGroups.any { it in connection.chains }
        }.forEach { connection ->
            mihomo.closeConnection(connection.id)
        }
    }

    private fun historyRuleIntent(raw: String): AiIntent? {
        val parsed = ConfigManager.parseAiRule(raw) ?: return null
        val matchType = AiIntent.MatchType.entries.firstOrNull {
            it.ruleToken == parsed.matchType
        } ?: return null
        return AiIntent(
            action = AiIntent.Action.ADD_RULE,
            target = parsed.target,
            matchType = matchType,
            proxyGroup = parsed.policy,
            replyMessage = "",
        )
    }

    private fun resolveAvailableRulePolicy(
        intent: AiIntent,
        snapshot: MihomoRepository.RoutingSnapshot,
    ): AiIntent? {
        if (!snapshot.isKnownUnavailable(intent.proxyGroup)) return intent
        val replacement = snapshot.availableEquivalent(intent.proxyGroup) ?: return null
        return intent.copy(
            proxyGroup = replacement.name,
            replyMessage = "已将 ${intent.target} 路由至 ${replacement.name}。",
        )
    }

    private fun normalizeGeositeIntent(intent: AiIntent): AiIntent {
        if (intent.matchType != AiIntent.MatchType.GEOSITE) return intent
        val canonical = canonicalGeositeTarget(intent.target)
            ?: throw PlanValidationException(
                "当前 geodata 不支持服务 ${intent.target}，请改用明确域名",
            )
        return if (canonical == intent.target) intent else intent.copy(target = canonical)
    }

    private inline fun requirePlan(value: Boolean, lazyMessage: () -> String) {
        if (!value) throw PlanValidationException(lazyMessage())
    }

    /** Builds e.g. `DOMAIN-SUFFIX,netflix.com,SG-狮城`. */
    private fun formatRule(intent: AiIntent): String =
        "${intent.matchType.ruleToken},${intent.target},${intent.proxyGroup}"

    private suspend fun refreshAffectedConnections(
        changedIntents: List<AiIntent>,
    ): ConnectionRefreshSummary {
        if (changedIntents.isEmpty()) return ConnectionRefreshSummary.NONE
        val connections = mihomo.getConnectionDetails().getOrElse {
            return ConnectionRefreshSummary(lookupFailed = true)
        }
        val affected = connections.filter { connection ->
            changedIntents.any { intent ->
                AiConnectionRefreshPolicy.shouldClose(intent, connection)
            }
        }
        var closed = 0
        affected.forEach { connection ->
            if (mihomo.closeConnection(connection.id)) closed++
        }
        return ConnectionRefreshSummary(
            matched = affected.size,
            closed = closed,
        )
    }

    private fun isSafeRule(intent: AiIntent, routingTargets: List<String>): Boolean {
        val target = intent.target
        val safeTarget = target.isNotBlank() && target.length <= 512 &&
            ',' !in target && '\n' !in target && '\r' !in target
        val allowedPolicies = routingTargets + listOf("DIRECT", "REJECT", "REJECT-DROP", "PASS")
        return safeTarget && intent.proxyGroup in allowedPolicies
    }

    private sealed interface PreparedOperation {
        val intent: AiIntent

        data class Rule(
            override val intent: AiIntent,
            val ruleLine: String,
        ) : PreparedOperation

        data class Switch(
            override val intent: AiIntent,
            val group: String,
            val previous: String?,
            val selected: MihomoRepository.ProxyState,
        ) : PreparedOperation

        data class NoMutation(
            override val intent: AiIntent,
        ) : PreparedOperation
    }

    private class PlanValidationException(message: String) : Exception(message)
    private class PlanCommitException(message: String) : Exception(message)
    private class HistoryUndoException(message: String) : Exception(message)

    private data class ConnectionRefreshSummary(
        val matched: Int = 0,
        val closed: Int = 0,
        val lookupFailed: Boolean = false,
    ) {
        val userMessage: String?
            get() = when {
                lookupFailed -> "规则已生效；如目标应用仍保持旧连接，请重新打开应用。"
                matched == 0 -> null
                closed == matched -> "已刷新 $closed 个旧连接，新请求将使用新出口。"
                else -> "已刷新 $closed/$matched 个旧连接；其余连接将在重连后使用新出口。"
            }

        companion object {
            val NONE = ConnectionRefreshSummary()
        }
    }

    internal companion object {
        const val CHECKPOINT_AFTER_RULE_RELOAD = "after_rule_reload"
        const val CHECKPOINT_AFTER_PROXY_SWITCH = "after_proxy_switch"
        private const val DEFAULT_HISTORY_SCOPE = "__default__"

        private val GEOSITE_ALIASES = mapOf(
            "google" to "google",
            "youtube" to "youtube",
            "netflix" to "netflix",
            "disney" to "disney",
            "disneyplus" to "disney",
            "disney+" to "disney",
            "openai" to "openai",
            "chatgpt" to "openai",
            "github" to "github",
            "spotify" to "spotify",
        )

        internal fun canonicalGeositeTarget(target: String): String? =
            target.trim().lowercase().replace(" ", "").let { normalized ->
                GEOSITE_ALIASES[normalized]
                    ?: normalized.takeIf { it.matches(Regex("""[a-z0-9@_-]{1,64}""")) }
            }

        internal fun ruleResultReply(intent: AiIntent, changed: Boolean): String {
            val destination = when (intent.proxyGroup) {
                "DIRECT" -> "DIRECT（直连）"
                "REJECT", "REJECT-DROP" -> "${intent.proxyGroup}（拦截）"
                else -> intent.proxyGroup
            }
            return if (changed) {
                "已将 ${intent.target} 的流量出口设为 $destination。"
            } else {
                "${intent.target} 已经路由至 $destination，无需重复添加。"
            }
        }
    }

    data class StepResult(
        val intent: AiIntent,
        val reloadStatus: Int?,
        val ruleLine: String?,
        val reply: String,
        val details: List<String> = emptyList(),
    )

    sealed interface Outcome {
        val message: String

        data class Success(
            val intent: AiIntent,
            val reloadStatus: Int?,
            val ruleLine: String?,
            val reply: String,
            val plan: AiPlan = AiPlan.single(intent),
            val stepResults: List<StepResult> = listOf(
                StepResult(intent, reloadStatus, ruleLine, reply),
            ),
            val resolvedLocally: Boolean = false,
        ) : Outcome {
            override val message: String get() = reply
        }

        data class Failure(
            override val message: String,
            val completed: List<StepResult> = emptyList(),
        ) : Outcome
    }

    sealed interface HistoryActionOutcome {
        val message: String

        data class Success(override val message: String) : HistoryActionOutcome
        data class Failure(override val message: String) : HistoryActionOutcome
    }

}
