package com.yamax.veer

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.TextFieldValue
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
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.StartupStage
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.core_mihomo.ipc.CoreStateClient
import com.yamax.veer.data.AiHistoryEntry
import com.yamax.veer.data.AiHistoryStore
import com.yamax.veer.data.ApiKeyStore
import com.yamax.veer.data.ConnectionStatusRepository
import com.yamax.veer.ui.HomePrimaryAction
import com.yamax.veer.ui.StartupProgressPanel
import com.yamax.veer.ui.ai.AiHistorySection
import com.yamax.veer.ui.ai.AiQuickTemplateRow
import com.yamax.veer.ui.aiExecutionReadiness
import com.yamax.veer.ui.connections.ConnectionsActivity
import com.yamax.veer.ui.home.ConnectionDashboardSection
import com.yamax.veer.ui.home.HomeScreen
import com.yamax.veer.ui.home.HomeScreenState
import com.yamax.veer.ui.homePrimaryAction
import com.yamax.veer.ui.logs.LogsActivity
import com.yamax.veer.ui.nodes.NodesActivity
import com.yamax.veer.ui.profile.ProfileActivity
import com.yamax.veer.ui.rules.RulesActivity
import com.yamax.veer.ui.settings.SettingsActivity
import com.yamax.veer.ui.theme.VeerTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                Scaffold(modifier = Modifier.fillMaxSize()) { inner ->
                    VeerHomeRoute(modifier = Modifier.padding(inner))
                }
            }
        }
    }
}

@Composable
private fun VeerHomeRoute(modifier: Modifier = Modifier) {
    val appState by AppStateRepository.appState.collectAsStateWithLifecycle()
    val engineState = appState.runtime.engineState
    val activeProfile = appState.profile.activeProfile
    val lifecycleOwner = LocalLifecycleOwner.current
    val uiLogLines = remember { mutableStateListOf<String>() }
    val coreLogLines = remember { mutableStateListOf<String>() }
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current
    val aiController = remember(context) { AiController(context.applicationContext) }
    val aiHistoryStore = remember(context) { AiHistoryStore.get(context.applicationContext) }
    val connectionStatusRepository = remember(context) {
        ConnectionStatusRepository(context.applicationContext)
    }

    // TextFieldValue preserves the active IME composition range for CJK input.
    var prompt by remember { mutableStateOf(TextFieldValue("")) }
    var aiBusy by remember { mutableStateOf(false) }
    var hasApiKey by remember { mutableStateOf(ApiKeyStore.hasUserKey(context)) }
    var aiFeedback by remember { mutableStateOf<String?>(null) }
    var aiFeedbackIsError by remember { mutableStateOf(false) }
    var aiHistory by remember { mutableStateOf<List<AiHistoryEntry>>(emptyList()) }
    var showLogs by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        MihomoEngine.logs.collect { line ->
            uiLogLines.add(line)
            if (uiLogLines.size > MAX_VISIBLE_LOG_LINES) uiLogLines.removeAt(0)
        }
    }

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
                    CoreStateClient.logSnapshot(limit = MAX_VISIBLE_LOG_LINES)
                }
                coreLogLines.clear()
                coreLogLines.addAll(snapshot)
                delay(LOG_REFRESH_INTERVAL_MS)
            }
        }
    }

    fun appendLog(line: String) {
        VeerLog.ui(line, VeerLog.Level.INFO)
    }

    val vpnPermissionLauncher = rememberLauncherForActivityResult(
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
            vpnPermissionLauncher.launch(prepareIntent)
        } else {
            ContextCompat.startForegroundService(context, VeerVpnService.startIntent(context))
        }
    }

    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {
        // Notification permission is recommended but not required to run the service.
        continueVpnStart()
    }

    fun requestStart() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
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
                            step.details.forEach { detail -> appendLog("AI →   $detail") }
                        }
                        appendLog("AI → ${outcome.reply}")
                    }

                    is AiController.Outcome.Failure -> {
                        aiFeedbackIsError = true
                        aiFeedback = outcome.message
                        outcome.completed.forEachIndexed { index, step ->
                            appendLog("AI → ${index + 1} complete: ${step.ruleLine ?: step.reply}")
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

    val primaryAction = homePrimaryAction(engineState, activeProfile != null)
    val aiReadiness = aiExecutionReadiness(
        engineState = engineState,
        hasActiveProfile = activeProfile != null,
        hasApiKey = hasApiKey,
    )
    val activeProfileName = activeProfile?.let { profile ->
        appState.profile.activeMetadata?.displayName ?: profile.profileId.value
    }

    HomeScreen(
        state = HomeScreenState(
            engineState = engineState,
            activeProfileName = activeProfileName,
            activeProfileHash = activeProfile?.generatedConfigHash,
            prompt = prompt,
            aiBusy = aiBusy,
            aiReadiness = aiReadiness,
            aiFeedback = aiFeedback,
            aiFeedbackIsError = aiFeedbackIsError,
            showLogs = showLogs,
            coreLogLines = coreLogLines,
            uiLogLines = uiLogLines,
        ),
        primaryActionLabel = stringResource(primaryAction.labelRes),
        primaryActionEnabled = primaryAction.enabled,
        onPrimaryAction = {
            when (primaryAction.action) {
                HomePrimaryAction.IMPORT_PROFILE -> context.open(ProfileActivity::class.java)
                HomePrimaryAction.START -> requestStart()
                HomePrimaryAction.STOP,
                HomePrimaryAction.RECOVER_ERROR,
                -> requestStop()
                HomePrimaryAction.STARTING,
                HomePrimaryAction.STOPPING,
                -> Unit
            }
        },
        onQuickReconnect = ::requestReconnect,
        onProfiles = { context.open(ProfileActivity::class.java) },
        onRules = { context.open(RulesActivity::class.java) },
        onNodes = { context.open(NodesActivity::class.java) },
        onConnections = { context.open(ConnectionsActivity::class.java) },
        onLogs = { context.open(LogsActivity::class.java) },
        onSettings = { context.open(SettingsActivity::class.java) },
        onPromptChange = { prompt = it },
        onSubmitPrompt = { submitPrompt() },
        onDismissFeedback = { aiFeedback = null },
        onToggleLogs = { showLogs = !showLogs },
        modifier = modifier,
        startupContent = {
            if (engineState is EngineState.Starting) {
                StartupProgressPanel(
                    stage = appState.runtime.startupStage ?: StartupStage.PREPARING_CONFIG,
                )
            }
        },
        connectionContent = {
            ConnectionDashboardSection(
                engineState = engineState,
                physicalNetworkAvailable = appState.connectivity.physicalNetworksAvailable > 0,
                repository = connectionStatusRepository,
            )
        },
        quickTemplatesContent = {
            AiQuickTemplateRow(
                enabled = !aiBusy,
                onSelect = { prompt = TextFieldValue(it) },
            )
        },
        historyContent = {
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
        },
    )
}

private fun android.content.Context.open(activity: Class<*>) {
    startActivity(Intent(this, activity))
}

private const val MAX_VISIBLE_LOG_LINES = 200
private const val LOG_REFRESH_INTERVAL_MS = 1_000L
