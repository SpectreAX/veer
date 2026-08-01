package com.yamax.veer.ui.perapp

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.data.PerAppProxyMode
import com.yamax.veer.ui.theme.VeerTheme

class PerAppProxyActivity : ComponentActivity() {
    private val viewModel: PerAppProxyViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                val state by viewModel.uiState.collectAsStateWithLifecycle()
                val appState by AppStateRepository.appState.collectAsStateWithLifecycle()
                PerAppProxyScreen(
                    state = state,
                    runtimeRunning = appState.runtime.engineState is EngineState.Running,
                    onBack = ::finish,
                    onModeChange = viewModel::setMode,
                    onTogglePackage = viewModel::togglePackage,
                    onSelectVisible = viewModel::selectVisible,
                    onClearSelection = viewModel::clearSelection,
                    onSave = viewModel::save,
                    onDismissMessage = viewModel::dismissMessage,
                )
            }
        }
    }
}

@Composable
private fun PerAppProxyScreen(
    state: PerAppProxyUiState,
    runtimeRunning: Boolean,
    onBack: () -> Unit,
    onModeChange: (PerAppProxyMode) -> Unit,
    onTogglePackage: (String) -> Unit,
    onSelectVisible: (Set<String>) -> Unit,
    onClearSelection: () -> Unit,
    onSave: (Boolean) -> Unit,
    onDismissMessage: () -> Unit,
) {
    var query by remember { mutableStateOf(TextFieldValue("")) }
    val visibleApps = remember(state.apps, query.text) {
        val needle = query.text.trim()
        if (needle.isEmpty()) {
            state.apps
        } else {
            state.apps.filter {
                it.label.contains(needle, ignoreCase = true) ||
                    it.packageName.contains(needle, ignoreCase = true)
            }
        }
    }

    Scaffold(modifier = Modifier.fillMaxSize()) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 16.dp),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp, bottom = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TextButton(onClick = onBack) { Text("返回") }
                Column(modifier = Modifier.weight(1f)) {
                    Text("应用分流", style = MaterialTheme.typography.headlineSmall)
                    Text(
                        if (runtimeRunning) "保存后将快速重连并立即生效" else "下次连接时生效",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            PerAppModeCard(
                selected = state.mode,
                onModeChange = onModeChange,
            )

            state.message?.let { message ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        message,
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    TextButton(onClick = onDismissMessage) { Text("关闭") }
                }
            }

            if (state.mode != PerAppProxyMode.ALL_APPS) {
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    label = { Text("搜索应用或包名") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        "已选 ${state.selectedPackages.size} · 可用 ${state.availableSelectedCount}",
                        modifier = Modifier.weight(1f),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    TextButton(
                        onClick = {
                            onSelectVisible(
                                visibleApps
                                    .filter(InstalledAppEntry::isAvailable)
                                    .mapTo(mutableSetOf(), InstalledAppEntry::packageName),
                            )
                        },
                        enabled = visibleApps.any(InstalledAppEntry::isAvailable),
                    ) {
                        Text("全选当前")
                    }
                    TextButton(
                        onClick = onClearSelection,
                        enabled = state.selectedPackages.isNotEmpty(),
                    ) {
                        Text("清空")
                    }
                }
            } else {
                Spacer(Modifier.height(10.dp))
                Text(
                    "除 Veer 自身外，设备上的所有应用都通过 VPN。Veer 自身始终绕过隧道以防止代理环路。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(10.dp))
            }

            when {
                state.loading -> Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator()
                }

                state.mode == PerAppProxyMode.ALL_APPS -> Spacer(Modifier.weight(1f))

                visibleApps.isEmpty() -> Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("没有匹配的应用")
                }

                else -> LazyColumn(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .testTag("per_app_list"),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(visibleApps, key = InstalledAppEntry::packageName) { app ->
                        AppSelectionRow(
                            app = app,
                            selected = app.packageName in state.selectedPackages,
                            onToggle = { onTogglePackage(app.packageName) },
                        )
                    }
                }
            }

            Button(
                onClick = { onSave(runtimeRunning) },
                enabled = state.canSave,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 12.dp)
                    .testTag("save_per_app_policy"),
            ) {
                Text(
                    when {
                        state.saving -> "正在保存…"
                        runtimeRunning -> "保存并快速重连"
                        else -> "保存"
                    },
                )
            }
        }
    }
}

@Composable
private fun PerAppModeCard(
    selected: PerAppProxyMode,
    onModeChange: (PerAppProxyMode) -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Column(modifier = Modifier.padding(vertical = 4.dp)) {
            ModeRow(
                mode = PerAppProxyMode.ALL_APPS,
                title = "代理所有应用",
                description = "默认模式，所有应用都通过 Veer",
                selected = selected,
                onModeChange = onModeChange,
            )
            ModeRow(
                mode = PerAppProxyMode.ONLY_SELECTED,
                title = "仅代理所选应用",
                description = "适合只让浏览器、流媒体等应用走代理",
                selected = selected,
                onModeChange = onModeChange,
            )
            ModeRow(
                mode = PerAppProxyMode.BYPASS_SELECTED,
                title = "绕过所选应用",
                description = "适合让银行、支付、游戏等应用直连",
                selected = selected,
                onModeChange = onModeChange,
            )
        }
    }
}

@Composable
private fun ModeRow(
    mode: PerAppProxyMode,
    title: String,
    description: String,
    selected: PerAppProxyMode,
    onModeChange: (PerAppProxyMode) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onModeChange(mode) }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(
            selected = selected == mode,
            onClick = { onModeChange(mode) },
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall)
            Text(
                description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun AppSelectionRow(
    app: InstalledAppEntry,
    selected: Boolean,
    onToggle: () -> Unit,
) {
    val context = LocalContext.current
    val icon = remember(app.packageName, app.isAvailable) {
        if (!app.isAvailable) {
            null
        } else {
            runCatching {
                context.packageManager
                    .getApplicationIcon(app.packageName)
                    .toBitmap(width = 40, height = 40)
                    .asImageBitmap()
            }.getOrNull()
        }
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onToggle)
            .padding(vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Image(
                bitmap = icon,
                contentDescription = null,
                modifier = Modifier.size(40.dp),
            )
        } else {
            Box(
                modifier = Modifier
                    .size(40.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("?")
            }
        }
        Spacer(Modifier.size(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                if (app.isAvailable) app.label else "${app.label}（不可用）",
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                buildString {
                    append(app.packageName)
                    if (app.isSystemApp) append(" · 系统")
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Checkbox(
            checked = selected,
            onCheckedChange = { onToggle() },
        )
    }
}
