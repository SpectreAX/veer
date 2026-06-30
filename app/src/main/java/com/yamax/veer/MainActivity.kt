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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_ai.AiController
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.VeerVpnService
import com.yamax.veer.data.ApiKeyStore
import com.yamax.veer.ui.profile.ProfileActivity
import com.yamax.veer.ui.theme.VeerTheme
import kotlinx.coroutines.launch

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
    val appState      by AppStateRepository.appState.collectAsState()
    val state          = appState.runtime.engineState
    val activeProfile  = appState.profile.activeProfile
    val logLines = remember { mutableStateListOf<String>() }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        MihomoEngine.logs.collect { line ->
            logLines.add(line)
            if (logLines.size > 200) logLines.removeAt(0)
        }
    }

    val context = androidx.compose.ui.platform.LocalContext.current
    val aiController = remember(context) { AiController(context.applicationContext) }
    var prompt by remember { mutableStateOf("把 google.com 切换到 TW 节点") }
    var aiBusy by remember { mutableStateOf(false) }
    var apiKey by remember { mutableStateOf(ApiKeyStore.deepseekKey(context)) }
    var apiKeyVisible by remember { mutableStateOf(false) }

    fun appendLog(line: String) {
        logLines.add(line)
        if (logLines.size > 200) logLines.removeAt(0)
    }

    val notificationPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* granted-or-not is fine; the service still runs */ }

    val vpnPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == ComponentActivity.RESULT_OK) {
            ContextCompat.startForegroundService(context, VeerVpnService.startIntent(context))
        } else {
            appendLog("VPN permission denied")
        }
    }

    fun requestStart() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) notificationPermLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        val prepareIntent = VpnService.prepare(context)
        if (prepareIntent != null) {
            vpnPermLauncher.launch(prepareIntent)
        } else {
            ContextCompat.startForegroundService(context, VeerVpnService.startIntent(context))
        }
    }

    fun requestStop() {
        ContextCompat.startForegroundService(context, VeerVpnService.stopIntent(context))
    }

    fun submitPrompt() {
        val text = prompt.trim()
        if (text.isEmpty() || aiBusy) return
        aiBusy = true
        appendLog("AI ← \"$text\"")
        scope.launch {
            try {
                when (val outcome = aiController.handle(text)) {
                    is AiController.Outcome.Success -> {
                        appendLog("AI → intent=${outcome.intent.action} rule=${outcome.ruleLine ?: "-"}")
                        appendLog("AI → reload HTTP=${outcome.reloadStatus ?: "n/a"}")
                        appendLog("AI → ${outcome.reply}")
                    }
                    is AiController.Outcome.Failure -> appendLog("AI ✗ ${outcome.message}")
                }
            } finally {
                aiBusy = false
            }
        }
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(text = "Veer · Phase 1.5", style = MaterialTheme.typography.headlineSmall)
        Text(text = "Status: ${state.label()}")

        // Snapshot the delegated property so smart casts work inside the else branch.
        val ap = activeProfile
        if (ap == null) {
            Text(
                text  = "⚠ No active profile — go to Profiles to import one before starting.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        } else {
            val profileName = appState.profile.activeMetadata?.displayName ?: ap.profileId.value
            Text(
                text  = "Profile: $profileName  (hash: ${ap.generatedConfigHash.take(8)}…)",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = ::requestStart,
                // Require an active profile: no profile → no VPN start.
                enabled = activeProfile != null
                    && state !is EngineState.Running
                    && state !is EngineState.Starting,
            ) { Text("Start VPN") }
            Button(
                onClick = ::requestStop,
                enabled = state is EngineState.Running || state is EngineState.Error,
            ) { Text("Stop VPN") }
            Button(
                onClick = { context.startActivity(android.content.Intent(context, ProfileActivity::class.java)) },
            ) { Text("Profiles") }
        }

        OutlinedTextField(
            value = apiKey,
            onValueChange = { apiKey = it },
            label = { Text("DeepSeek API Key") },
            placeholder = { Text("sk-…") },
            singleLine = true,
            visualTransformation = if (apiKeyVisible) VisualTransformation.None
                else PasswordVisualTransformation(),
            modifier = Modifier.fillMaxWidth(),
            supportingText = {
                Text(
                    if (ApiKeyStore.hasUserKey(context)) "Saved (taps Save to overwrite)"
                    else "Not saved — falling back to BuildConfig"
                )
            },
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = {
                    ApiKeyStore.setDeepseekKey(context, apiKey)
                    appendLog("API key saved (${apiKey.length} chars)")
                },
                enabled = apiKey.isNotBlank(),
            ) { Text("Save Key") }
            TextButton(onClick = { apiKeyVisible = !apiKeyVisible }) {
                Text(if (apiKeyVisible) "Hide" else "Show")
            }
            TextButton(
                onClick = {
                    ApiKeyStore.clearDeepseekKey(context)
                    apiKey = ""
                    appendLog("API key cleared")
                },
            ) { Text("Clear") }
        }

        OutlinedTextField(
            value = prompt,
            onValueChange = { prompt = it },
            label = { Text("AI prompt") },
            modifier = Modifier.fillMaxWidth(),
            enabled = !aiBusy,
        )
        Button(
            onClick = ::submitPrompt,
            enabled = !aiBusy && prompt.isNotBlank() && state is EngineState.Running,
        ) {
            Text(if (aiBusy) "Sending…" else "Send to AI")
        }

        Text(text = "Log", style = MaterialTheme.typography.titleMedium)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(8.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            if (logLines.isEmpty()) {
                Text(text = "(no events yet)", style = MaterialTheme.typography.bodySmall)
            } else {
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

private fun EngineState.label(): String = when (this) {
    EngineState.Stopped  -> "Stopped"
    EngineState.Starting -> "Starting…"
    EngineState.Running  -> "Running"
    EngineState.Stopping -> "Stopping…"
    is EngineState.Error -> "Error: $message"
}
