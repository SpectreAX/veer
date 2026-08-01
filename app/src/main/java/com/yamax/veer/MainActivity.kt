package com.yamax.veer

import android.Manifest
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_ai.AiController
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.CoreRuntimeEvents
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.StartupStage
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.core_mihomo.ipc.CoreStateClient
import com.yamax.veer.data.ApiKeyStore
import com.yamax.veer.data.AiHistoryEntry
import com.yamax.veer.data.AiHistoryStore
import com.yamax.veer.data.ConnectionHomeStatus
import com.yamax.veer.data.ConnectionStatusRepository
import com.yamax.veer.data.DashboardRefreshCadence
import com.yamax.veer.ui.AiExecutionReadiness
import com.yamax.veer.ui.HomePrimaryAction
import com.yamax.veer.ui.aiExecutionReadiness
import com.yamax.veer.ui.canExecute
import com.yamax.veer.ui.guidanceRes
import com.yamax.veer.ui.homePrimaryAction
import com.yamax.veer.ui.StartupProgressPanel
import com.yamax.veer.ui.profile.ProfileActivity
import com.yamax.veer.ui.rules.RulesActivity
import com.yamax.veer.ui.nodes.NodesActivity
import com.yamax.veer.ui.logs.LogsActivity
import com.yamax.veer.ui.connections.ConnectionsActivity
import com.yamax.veer.ui.ai.AiHistorySection
import com.yamax.veer.ui.ai.AiQuickTemplateRow
import com.yamax.veer.ui.settings.SettingsActivity
import com.yamax.veer.ui.theme.VeerTheme
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                Scaffold(modifier = Modifier.fillMaxSize()) { inner ->
                    Phase15Screen(modifier = Modifier.padding(inner))
                }
            }
        }
    }
}

@Composable
private fun Phase15Screen(modifier: Modifier = Modifier) {
    val appState      by AppStateRepository.appState.collectAsStateWithLifecycle()
    val state          = appState.runtime.engineState
    val activeProfile  = appState.profile.activeProfile
    val lifecycleOwner = LocalLifecycleOwner.current
    val logLines = remember { mutableStateListOf<String>() }
    val coreLogLines = remember { mutableStateListOf<String>() }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        MihomoEngine.logs.collect { line ->
            logLines.add(line)
            if (logLines.size > 200) logLines.removeAt(0)
        }
    }

    val context = androidx.compose.ui.platform.LocalContext.current
    val aiController = remember(context) { AiController(context.applicationContext) }
    val aiHistoryStore = remember(context) { AiHistoryStore.get(context.applicationContext) }
    val connectionStatusRepository = remember(context) {
        ConnectionStatusRepository(context.applicationContext)
    }
    // Keep the full TextFieldValue so composing text from Chinese/Japanese/Korean
    // IMEs survives recomposition. Reducing it to String on every keystroke drops
    // the IME composition range on some keyboards and prevents candidate commit.
    var prompt by remember {
        mutableStateOf(TextFieldValue(""))
    }
    var aiBusy by remember { mutableStateOf(false) }
    var hasApiKey by remember { mutableStateOf(ApiKeyStore.hasUserKey(context)) }
    var aiFeedback by remember { mutableStateOf<String?>(null) }
    var aiFeedbackIsError by remember { mutableStateOf(false) }
    var aiHistory by remember { mutableStateOf<List<AiHistoryEntry>>(emptyList()) }
    var showLogs by remember { mutableStateOf(false) }

    DisposableEffect(context, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                hasApiKey = ApiKeyStore.hasUserKey(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(activeProfile?.profileId?.value) {
        aiHistory = withContext(Dispatchers.IO) { aiHistoryStore.entries() }
    }

    LaunchedEffect(showLogs, lifecycleOwner) {
        if (!showLogs) return@LaunchedEffect
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (true) {
                val snapshot = withContext(Dispatchers.IO) {
                    CoreStateClient.logSnapshot(limit = 200)
                }
                coreLogLines.clear()
                coreLogLines.addAll(snapshot)
                delay(1_000)
            }
        }
    }

    fun appendLog(line: String) {
        VeerLog.ui(line, VeerLog.Level.INFO)
    }

    val vpnPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == ComponentActivity.RESULT_OK) {
            ContextCompat.startForegroundService(context, VeerVpnService.startIntent(context))
        } else {
            appendLog("VPN permission denied")
        }
    }

    fun continueVpnStart() {
        val prepareIntent = VpnService.prepare(context)
        if (prepareIntent != null) {
            vpnPermLauncher.launch(prepareIntent)
        } else {
            ContextCompat.startForegroundService(context, VeerVpnService.startIntent(context))
        }
    }

    val notificationPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {
        // Notification permission is recommended but not required to operate
        // the foreground service. Continue the same user-initiated start flow.
        continueVpnStart()
    }

    fun requestStart() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                notificationPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                return
            }
        }
        continueVpnStart()
    }

    fun requestStop() {
        ContextCompat.startForegroundService(context, VeerVpnService.stopIntent(context))
    }

    fun requestReconnect() {
        ContextCompat.startForegroundService(context, VeerVpnService.reconnectIntent(context))
    }

    fun refreshAiHistory() {
        scope.launch {
            aiHistory = withContext(Dispatchers.IO) { aiHistoryStore.entries() }
        }
    }

    fun submitPrompt(textOverride: String? = null) {
        val text = (textOverride ?: prompt.text).trim()
        if (text.isEmpty() || aiBusy) return
        aiBusy = true
        appendLog("AI ← \"$text\"")
        scope.launch {
            try {
                when (val outcome = aiController.handle(text)) {
                    is AiController.Outcome.Success -> {
                        aiFeedbackIsError = false
                        aiFeedback = outcome.reply
                        appendLog(
                            "AI → plan v${outcome.plan.schemaVersion} · " +
                                "${outcome.stepResults.size} operation(s)",
                        )
                        outcome.stepResults.forEachIndexed { index, step ->
                            appendLog(
                                "AI → ${index + 1}/${outcome.stepResults.size} " +
                                    "intent=${step.intent.action} result=${step.ruleLine ?: "-"} " +
                                    "HTTP=${step.reloadStatus ?: "n/a"}",
                            )
                            step.details.forEach { detail ->
                                appendLog("AI →   $detail")
                            }
                        }
                        appendLog("AI → ${outcome.reply}")
                    }
                    is AiController.Outcome.Failure -> {
                        aiFeedbackIsError = true
                        aiFeedback = outcome.message
                        outcome.completed.forEachIndexed { index, step ->
                            appendLog(
                                "AI → ${index + 1} complete: ${step.ruleLine ?: step.reply}",
                            )
                        }
                        appendLog("AI ✗ ${outcome.message}")
                    }
                }
            } finally {
                aiBusy = false
                refreshAiHistory()
            }
        }
    }

    fun undoHistory(entry: AiHistoryEntry) {
        if (aiBusy) return
        aiBusy = true
        scope.launch {
            try {
                when (val outcome = aiController.undoHistory(entry.id)) {
                    is AiController.HistoryActionOutcome.Success -> {
                        aiFeedbackIsError = false
                        aiFeedback = outcome.message
                        appendLog("AI ↶ ${outcome.message}")
                    }
                    is AiController.HistoryActionOutcome.Failure -> {
                        aiFeedbackIsError = true
                        aiFeedback = outcome.message
                        appendLog("AI ↶ failed: ${outcome.message}")
                    }
                }
            } finally {
                aiBusy = false
                refreshAiHistory()
            }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(text = "Veer", style = MaterialTheme.typography.headlineSmall)
        Text(text = stringResource(R.string.home_runtime_status, state.localizedLabel()))

        // Snapshot the delegated property so smart casts work inside the else branch.
        val ap = activeProfile
        if (ap == null) {
            Text(
                text = stringResource(R.string.home_no_profile),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        } else {
            val profileName = appState.profile.activeMetadata?.displayName ?: ap.profileId.value
            Text(
                text = stringResource(
                    R.string.home_active_profile,
                    profileName,
                    ap.generatedConfigHash.take(8),
                ),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
        }

        if (state is EngineState.Starting) {
            StartupProgressPanel(
                stage = appState.runtime.startupStage ?: StartupStage.PREPARING_CONFIG,
            )
        }

        ConnectionDashboardSection(
            engineState = state,
            physicalNetworkAvailable = appState.connectivity.physicalNetworksAvailable > 0,
            repository = connectionStatusRepository,
        )

        val primaryAction = homePrimaryAction(state, activeProfile != null)
        Button(
            onClick = {
                when (primaryAction.action) {
                    HomePrimaryAction.IMPORT_PROFILE ->
                        context.startActivity(android.content.Intent(context, ProfileActivity::class.java))
                    HomePrimaryAction.START -> requestStart()
                    HomePrimaryAction.STOP,
                    HomePrimaryAction.RECOVER_ERROR -> requestStop()
                    HomePrimaryAction.STARTING,
                    HomePrimaryAction.STOPPING -> Unit
                }
            },
            enabled = primaryAction.enabled,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("primary_vpn_action"),
        ) {
            Text(stringResource(primaryAction.labelRes))
        }
        if (state is EngineState.Running) {
            OutlinedButton(
                onClick = { requestReconnect() },
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("quick_reconnect_action"),
            ) {
                Text(stringResource(R.string.home_quick_reconnect))
            }
        }

        Text(stringResource(R.string.home_quick_actions), style = MaterialTheme.typography.titleMedium)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = { context.startActivity(android.content.Intent(context, ProfileActivity::class.java)) },
                modifier = Modifier.weight(1f),
            ) { Text(stringResource(R.string.home_profiles)) }
            OutlinedButton(
                onClick = { context.startActivity(android.content.Intent(context, RulesActivity::class.java)) },
                modifier = Modifier.weight(1f),
            ) { Text(stringResource(R.string.home_ai_rules)) }
            OutlinedButton(
                onClick = { context.startActivity(android.content.Intent(context, NodesActivity::class.java)) },
                enabled = state is EngineState.Running,
                modifier = Modifier.weight(1f),
            ) { Text(stringResource(R.string.home_nodes)) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        android.content.Intent(context, ConnectionsActivity::class.java),
                    )
                },
                enabled = state is EngineState.Running,
                modifier = Modifier.weight(1f),
            ) {
                Text(stringResource(R.string.home_connections))
            }
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        android.content.Intent(context, LogsActivity::class.java),
                    )
                },
                modifier = Modifier.weight(1f),
            ) {
                Text(stringResource(R.string.home_live_logs))
            }
            OutlinedButton(
                onClick = {
                    context.startActivity(
                        android.content.Intent(context, SettingsActivity::class.java),
                    )
                },
                modifier = Modifier.weight(1f),
            ) {
                Text(stringResource(R.string.home_settings))
            }
        }

        Text(stringResource(R.string.home_ai_command), style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(
            value = prompt,
            onValueChange = { prompt = it },
            label = { Text("AI prompt") },
            placeholder = { Text(stringResource(R.string.home_ai_prompt_placeholder)) },
            modifier = Modifier
                .fillMaxWidth()
                .testTag("ai_prompt"),
            enabled = !aiBusy,
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Text,
                imeAction = ImeAction.Send,
            ),
            keyboardActions = KeyboardActions(onSend = { submitPrompt() }),
        )

        if (prompt.text.isBlank()) {
            AiQuickTemplateRow(
                enabled = !aiBusy,
                onSelect = { resolvedPrompt ->
                    prompt = TextFieldValue(resolvedPrompt)
                },
            )
        }

        val aiReadiness = aiExecutionReadiness(
            engineState = state,
            hasActiveProfile = activeProfile != null,
            hasApiKey = hasApiKey,
        )
        Text(
            stringResource(aiReadiness.guidanceRes()),
            style = MaterialTheme.typography.bodySmall,
            color = if (aiReadiness.canExecute) {
                MaterialTheme.colorScheme.onSurfaceVariant
            } else {
                MaterialTheme.colorScheme.error
            },
        )
        Button(
            onClick = { submitPrompt() },
            enabled = !aiBusy &&
                prompt.text.isNotBlank() &&
                aiReadiness.canExecute,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                when {
                    aiBusy -> stringResource(R.string.home_ai_executing)
                    aiReadiness == AiExecutionReadiness.VPN_NOT_RUNNING ->
                        stringResource(R.string.home_ai_connect_first)
                    aiReadiness == AiExecutionReadiness.LOCAL_ONLY ->
                        stringResource(R.string.home_ai_execute_local)
                    aiReadiness == AiExecutionReadiness.NO_PROFILE ->
                        stringResource(R.string.home_ai_import_first)
                    else -> stringResource(R.string.home_ai_execute)
                }
            )
        }

        aiFeedback?.let { feedback ->
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(
                        if (aiFeedbackIsError) MaterialTheme.colorScheme.errorContainer
                        else MaterialTheme.colorScheme.primaryContainer,
                    )
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    stringResource(
                        if (aiFeedbackIsError) R.string.home_ai_failed
                        else R.string.home_ai_complete,
                    ),
                    style = MaterialTheme.typography.titleSmall,
                )
                Text(feedback, style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = { aiFeedback = null }) {
                    Text(stringResource(R.string.common_close))
                }
            }
        }

        AiHistorySection(
            entries = aiHistory,
            activeProfileId = activeProfile?.profileId?.value,
            busy = aiBusy,
            onReplay = { entry ->
                prompt = TextFieldValue(entry.prompt)
                submitPrompt(entry.prompt)
            },
            onUndo = ::undoHistory,
        )

        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.home_runtime_logs), style = MaterialTheme.typography.titleMedium)
                Text(
                    stringResource(R.string.home_log_count, logLines.size + coreLogLines.size),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            TextButton(onClick = { showLogs = !showLogs }) {
                Text(
                    stringResource(
                        if (showLogs) R.string.common_collapse else R.string.home_view,
                    ),
                )
            }
        }
        if (showLogs) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(320.dp)
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(8.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                if (coreLogLines.isEmpty() && logLines.isEmpty()) {
                    Text(
                        text = stringResource(R.string.home_no_events),
                        style = MaterialTheme.typography.bodySmall,
                    )
                } else {
                    if (coreLogLines.isNotEmpty()) {
                        Text(
                            text = stringResource(R.string.home_core_process),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                    coreLogLines.forEach { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        )
                    }
                    if (logLines.isNotEmpty()) {
                        Text(
                            text = stringResource(R.string.home_ui_process),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                    logLines.forEach { line ->
                        Text(
                            text = line,
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ConnectionDashboardSection(
    engineState: EngineState,
    physicalNetworkAvailable: Boolean,
    repository: ConnectionStatusRepository,
) {
    val lifecycleOwner = LocalLifecycleOwner.current
    var status by remember { mutableStateOf(ConnectionHomeStatus()) }
    var refreshing by remember { mutableStateOf(false) }
    val refreshMutex = remember { Mutex() }

    LaunchedEffect(engineState, lifecycleOwner, repository) {
        if (engineState !is EngineState.Running) {
            repository.resetSpeedHistory()
            status = ConnectionHomeStatus()
            refreshing = false
            return@LaunchedEffect
        }
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            repository.resumeSpeedSampling()

            suspend fun refresh(full: Boolean) {
                refreshMutex.withLock {
                    if (full) refreshing = true
                    try {
                        status = if (full) {
                            repository.snapshot(status)
                        } else {
                            repository.trafficSnapshot(status)
                        }
                    } finally {
                        if (full) refreshing = false
                    }
                }
            }

            coroutineScope {
                launch {
                    refresh(full = true)
                    while (true) {
                        delay(DashboardRefreshCadence.NETWORK_MS)
                        refresh(full = true)
                    }
                }
                launch {
                    delay(DashboardRefreshCadence.LIGHTWEIGHT_MS)
                    while (true) {
                        refresh(full = false)
                        delay(DashboardRefreshCadence.LIGHTWEIGHT_MS)
                    }
                }
                launch {
                    CoreRuntimeEvents.mutations.collect {
                        refresh(full = true)
                    }
                }
            }
        }
    }

    ConnectionOverviewCard(
        engineState = engineState,
        physicalNetworkAvailable = physicalNetworkAvailable,
        status = status,
        refreshing = refreshing,
    )
    SpeedChartSection(
        repository = repository,
        connected = engineState is EngineState.Running,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    )
}

@Composable
private fun SpeedChartSection(
    repository: ConnectionStatusRepository,
    connected: Boolean,
    modifier: Modifier = Modifier,
) {
    val history by repository.speedHistory.collectAsStateWithLifecycle()
    com.yamax.veer.ui.chart.SpeedChart(
        history = history,
        connected = connected,
        modifier = modifier,
    )
}

@Composable
private fun ConnectionOverviewCard(
    engineState: EngineState,
    physicalNetworkAvailable: Boolean,
    status: ConnectionHomeStatus,
    refreshing: Boolean,
) {
    val vpnConnected = engineState is EngineState.Running
    val exitIp = listOfNotNull(
        status.exit.ipv4?.let { "IPv4 $it" },
        status.exit.ipv6?.let { "IPv6 $it" },
    ).joinToString(" · ").ifEmpty { stringResource(R.string.connection_exit_ip_pending) }
    val route = listOfNotNull(
        status.selectedPolicy?.let { policy ->
            status.runtimeMode?.let { "$policy[$it]" } ?: policy
        },
        status.selectedNode,
        status.nodeDelayMs?.let { "${it}ms" },
    ).joinToString(" → ").ifEmpty { stringResource(R.string.connection_route_pending) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection_overview")
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text(
                stringResource(R.string.connection_title),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            if (refreshing) {
                Text(
                    stringResource(R.string.connection_checking),
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        StatusLine("VPN", vpnConnected, engineState.localizedLabel())
        StatusLine(
            "Mihomo",
            status.controllerReachable,
            stringResource(
                if (status.controllerReachable) R.string.connection_controller_ready
                else R.string.connection_controller_unavailable,
            ),
        )
        StatusLine(
            stringResource(R.string.connection_internet),
            status.internetReachable,
            when {
                !vpnConnected -> stringResource(R.string.connection_not_checked_stopped)
                !physicalNetworkAvailable ->
                    stringResource(R.string.connection_physical_unavailable)
                status.internetReachable -> stringResource(
                    R.string.connection_reachable,
                    status.internetLatencyMs?.let { " · ${it}ms" }.orEmpty(),
                )
                else -> stringResource(R.string.connection_access_failed)
            },
        )
        Text(
            stringResource(R.string.connection_exit, status.exit.locationLabel, exitIp),
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            stringResource(R.string.connection_route, route),
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            stringResource(
                R.string.connection_traffic,
                formatBytes(status.downloadTotal),
                formatBytes(status.uploadTotal),
                status.activeConnections,
                status.activeRuleCount,
            ),
            style = MaterialTheme.typography.bodySmall,
        )
    }
}

@Composable
private fun StatusLine(label: String, healthy: Boolean, detail: String) {
    Text(
        text = stringResource(
            R.string.connection_status_line,
            if (healthy) "●" else "○",
            label,
            detail,
        ),
        color = if (healthy) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurfaceVariant,
        style = MaterialTheme.typography.bodySmall,
    )
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024L * 1024L * 1024L -> "%.1f GB".format(bytes / (1024.0 * 1024.0 * 1024.0))
    bytes >= 1024L * 1024L -> "%.1f MB".format(bytes / (1024.0 * 1024.0))
    bytes >= 1024L -> "%.1f KB".format(bytes / 1024.0)
    else -> "$bytes B"
}

@Composable
private fun EngineState.localizedLabel(): String = when (this) {
    EngineState.Stopped -> stringResource(R.string.engine_stopped)
    EngineState.Starting -> stringResource(R.string.engine_starting)
    EngineState.Running -> stringResource(R.string.engine_running)
    EngineState.Stopping -> stringResource(R.string.engine_stopping)
    is EngineState.Error -> stringResource(R.string.engine_error, message)
}
