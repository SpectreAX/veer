package com.yamax.veer.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.yamax.veer.core.EngineState
import com.yamax.veer.ui.theme.VeerLime
import com.yamax.veer.ui.theme.VeerOutline
import com.yamax.veer.ui.theme.VeerSurface
import com.yamax.veer.ui.theme.VeerSurfaceRaised
import com.yamax.veer.ui.theme.VeerText
import com.yamax.veer.ui.theme.VeerTextMuted
import com.yamax.veer.ui.theme.VeerTheme

@Composable
fun VeerApp(viewModel: HomeViewModel = viewModel()) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Box(modifier = Modifier.weight(1f)) {
            when (state.destination) {
                AppDestination.Home -> HomeScreen(
                    state = state,
                    onCommandChange = viewModel::updateCommand,
                    onApplyCommand = viewModel::applyCommand,
                )

                AppDestination.Rules -> RulesScreen(state)
                AppDestination.Profile -> ProfileScreen(state)
            }
        }
        VeerNavigationBar(
            selected = state.destination,
            onSelect = viewModel::selectDestination,
        )
    }
}

@Composable
private fun HomeScreen(
    state: HomeUiState,
    onCommandChange: (String) -> Unit,
    onApplyCommand: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 22.dp),
    ) {
        Header()
        Spacer(Modifier.height(30.dp))
        RuntimeCard(state)
        Spacer(Modifier.height(18.dp))
        CommandCard(
            command = state.command,
            enabled = state.isRuntimeAvailable,
            onCommandChange = onCommandChange,
            onApplyCommand = onApplyCommand,
        )
        Spacer(Modifier.height(18.dp))
        ProfileCard(state)
        Spacer(Modifier.height(28.dp))
    }
}

@Composable
private fun RulesScreen(state: HomeUiState) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 22.dp),
    ) {
        ScreenHeader(
            eyebrow = "ROUTING",
            title = "规则",
            description = "查看 Veer 根据你的指令生成的分流规则。",
        )
        Spacer(Modifier.height(28.dp))

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Bottom,
        ) {
            Text(
                text = state.activeRuleCount.toString().padStart(2, '0'),
                color = VeerLime,
                style = MaterialTheme.typography.displayLarge,
            )
            Spacer(Modifier.width(10.dp))
            Text(
                text = "条活动规则",
                color = VeerTextMuted,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(bottom = 7.dp),
            )
        }
        Spacer(Modifier.height(18.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(VeerSurface, RoundedCornerShape(26.dp))
                .border(1.dp, VeerOutline, RoundedCornerShape(26.dp))
                .padding(horizontal = 24.dp, vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                modifier = Modifier
                    .size(64.dp)
                    .background(VeerSurfaceRaised, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                RouteGlyph()
            }
            Spacer(Modifier.height(18.dp))
            Text("还没有规则", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            Text(
                text = "接入配置与 Veercore 后，你在首页输入的指令会在这里形成可检查、可撤销的规则。",
                color = VeerTextMuted,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
            )
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun ProfileScreen(state: HomeUiState) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 22.dp),
    ) {
        ScreenHeader(
            eyebrow = "SETUP",
            title = "配置",
            description = "在启动网络前，把每一项依赖都准备好。",
        )
        Spacer(Modifier.height(28.dp))

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(VeerSurface, RoundedCornerShape(26.dp))
                .border(1.dp, VeerOutline, RoundedCornerShape(26.dp))
                .padding(20.dp),
        ) {
            Text("启动就绪度", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(18.dp))
            ReadinessRow(
                title = "代理配置",
                detail = state.profileName,
                ready = false,
            )
            ReadinessDivider()
            ReadinessRow(
                title = "Veercore",
                detail = "等待 gomobile AAR / Go Bridge",
                ready = state.isRuntimeAvailable,
            )
            ReadinessDivider()
            ReadinessRow(
                title = "治理契约",
                detail = "缺少 6 份生命周期文档",
                ready = false,
            )
        }

        Spacer(Modifier.height(18.dp))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(VeerSurfaceRaised, RoundedCornerShape(20.dp))
                .padding(18.dp),
        ) {
            Text("为什么暂时不能导入？", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(7.dp))
            Text(
                text = "开发记录要求先恢复运行时契约，再修改配置导入与启动链路。当前界面保留真实状态，不用模拟成功掩盖缺失依赖。",
                color = VeerTextMuted,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun ScreenHeader(
    eyebrow: String,
    title: String,
    description: String,
) {
    Column(modifier = Modifier.padding(top = 24.dp)) {
        Text(
            text = eyebrow,
            color = VeerLime,
            style = MaterialTheme.typography.labelLarge,
        )
        Spacer(Modifier.height(8.dp))
        Text(text = title, style = MaterialTheme.typography.displayLarge)
        Spacer(Modifier.height(8.dp))
        Text(
            text = description,
            color = VeerTextMuted,
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@Composable
private fun ReadinessRow(
    title: String,
    detail: String,
    ready: Boolean,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(10.dp)
                .background(if (ready) VeerLime else VeerTextMuted, CircleShape),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(3.dp))
            Text(detail, color = VeerTextMuted, style = MaterialTheme.typography.bodyMedium)
        }
        Text(
            text = if (ready) "就绪" else "待完成",
            color = if (ready) VeerLime else VeerTextMuted,
            style = MaterialTheme.typography.labelLarge,
        )
    }
}

@Composable
private fun ReadinessDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 16.dp)
            .height(1.dp)
            .background(VeerOutline),
    )
}

@Composable
private fun VeerNavigationBar(
    selected: AppDestination,
    onSelect: (AppDestination) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .background(VeerSurface, RoundedCornerShape(22.dp))
            .border(1.dp, VeerOutline, RoundedCornerShape(22.dp))
            .padding(6.dp),
    ) {
        AppDestination.entries.forEach { destination ->
            val isSelected = destination == selected
            Column(
                modifier = Modifier
                    .weight(1f)
                    .background(
                        color = if (isSelected) VeerSurfaceRaised else androidx.compose.ui.graphics.Color.Transparent,
                        shape = RoundedCornerShape(16.dp),
                    )
                    .clickable { onSelect(destination) }
                    .padding(vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = destination.glyph,
                    color = if (isSelected) VeerLime else VeerTextMuted,
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = destination.label,
                    color = if (isSelected) VeerText else VeerTextMuted,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
    }
}

@Composable
private fun Header() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(42.dp)
                .background(VeerLime, RoundedCornerShape(13.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = "V",
                color = MaterialTheme.colorScheme.onPrimary,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Black,
            )
        }
        Spacer(Modifier.width(12.dp))
        Column {
            Text(
                text = "VEER",
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                text = "让流量换个方向",
                color = VeerTextMuted,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        Spacer(Modifier.weight(1f))
        Box(
            modifier = Modifier
                .border(1.dp, VeerOutline, CircleShape)
                .padding(horizontal = 12.dp, vertical = 7.dp),
        ) {
            Text("MVP · 01", color = VeerTextMuted, style = MaterialTheme.typography.labelLarge)
        }
    }
}

@Composable
private fun RuntimeCard(state: HomeUiState) {
    val stateText = when (state.engineState) {
        EngineState.Stopped -> "尚未连接"
        EngineState.Starting -> "正在启动"
        EngineState.Running -> "已连接"
        EngineState.Stopping -> "正在停止"
        is EngineState.Error -> "发生错误"
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(VeerSurface, RoundedCornerShape(30.dp))
            .border(1.dp, VeerOutline, RoundedCornerShape(30.dp))
            .padding(horizontal = 24.dp, vertical = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = "网络控制",
            color = VeerTextMuted,
            style = MaterialTheme.typography.labelLarge,
        )
        Spacer(Modifier.height(18.dp))
        PowerButton(enabled = state.isRuntimeAvailable)
        Spacer(Modifier.height(18.dp))
        Text(stateText, style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(7.dp))
        Text(
            text = if (state.isRuntimeAvailable) {
                "轻触以改变连接状态"
            } else {
                "等待接入 Veercore 与配置文件"
            },
            color = VeerTextMuted,
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun PowerButton(enabled: Boolean) {
    val ringColor = if (enabled) VeerLime else VeerOutline
    val iconColor = if (enabled) VeerLime else VeerTextMuted

    Box(
        modifier = Modifier
            .size(136.dp)
            .background(VeerSurfaceRaised, CircleShape)
            .border(1.dp, ringColor.copy(alpha = 0.5f), CircleShape)
            .clickable(enabled = enabled) { },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(56.dp)) {
            drawArc(
                color = iconColor,
                startAngle = -48f,
                sweepAngle = 276f,
                useCenter = false,
                style = Stroke(width = 5.dp.toPx(), cap = StrokeCap.Round),
            )
            drawLine(
                color = iconColor,
                start = Offset(size.width / 2, 2.dp.toPx()),
                end = Offset(size.width / 2, 27.dp.toPx()),
                strokeWidth = 5.dp.toPx(),
                cap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun CommandCard(
    command: String,
    enabled: Boolean,
    onCommandChange: (String) -> Unit,
    onApplyCommand: () -> Unit,
) {
    val focusManager = LocalFocusManager.current
    var commandValue by remember { mutableStateOf(TextFieldValue(command)) }

    // External events (for example, applying a command) may clear the field.
    // Never replace an active IME composition, or Chinese candidates cannot commit.
    LaunchedEffect(command) {
        if (command != commandValue.text && commandValue.composition == null) {
            commandValue = TextFieldValue(command)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(VeerSurface, RoundedCornerShape(24.dp))
            .border(1.dp, VeerOutline, RoundedCornerShape(24.dp))
            .padding(20.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Text("告诉 Veer 怎么走", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text(
                    "用自然语言添加一条分流规则",
                    color = VeerTextMuted,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            Text(
                text = "${command.length}/120",
                color = VeerTextMuted,
                style = MaterialTheme.typography.bodyMedium,
            )
        }
        Spacer(Modifier.height(16.dp))
        OutlinedTextField(
            value = commandValue,
            onValueChange = {
                if (it.text.length <= 120) {
                    commandValue = it
                    onCommandChange(it.text)
                }
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled,
            placeholder = {
                Text("例如：Google 走台湾", color = VeerTextMuted)
            },
            shape = RoundedCornerShape(16.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = VeerLime,
                unfocusedBorderColor = VeerOutline,
                disabledBorderColor = VeerOutline,
                disabledContainerColor = VeerSurfaceRaised,
                focusedTextColor = VeerText,
                unfocusedTextColor = VeerText,
            ),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Text,
                imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(
                onDone = {
                    onApplyCommand()
                    focusManager.clearFocus()
                },
            ),
            singleLine = true,
        )
        Spacer(Modifier.height(12.dp))
        Button(
            onClick = onApplyCommand,
            modifier = Modifier.fillMaxWidth(),
            enabled = enabled && command.isNotBlank(),
            shape = RoundedCornerShape(14.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = VeerLime,
                contentColor = MaterialTheme.colorScheme.onPrimary,
                disabledContainerColor = VeerSurfaceRaised,
                disabledContentColor = VeerTextMuted,
            ),
        ) {
            Text("应用规则", modifier = Modifier.padding(vertical = 5.dp))
        }
    }
}

@Composable
private fun ProfileCard(state: HomeUiState) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(VeerSurface, RoundedCornerShape(22.dp))
            .border(1.dp, VeerOutline, RoundedCornerShape(22.dp))
            .padding(20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(46.dp)
                .background(VeerSurfaceRaised, RoundedCornerShape(14.dp)),
            contentAlignment = Alignment.Center,
        ) {
            RouteGlyph()
        }
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text("当前配置", color = VeerTextMuted, style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(3.dp))
            Text(state.profileName, style = MaterialTheme.typography.titleMedium)
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(
                text = state.activeRuleCount.toString(),
                color = VeerLime,
                style = MaterialTheme.typography.headlineMedium,
            )
            Text("条规则", color = VeerTextMuted, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@Composable
private fun RouteGlyph() {
    Canvas(Modifier.size(24.dp)) {
        val width = 2.dp.toPx()
        drawLine(
            color = VeerLime,
            start = Offset(3.dp.toPx(), 4.dp.toPx()),
            end = Offset(3.dp.toPx(), 20.dp.toPx()),
            strokeWidth = width,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = VeerLime,
            start = Offset(3.dp.toPx(), 8.dp.toPx()),
            end = Offset(20.dp.toPx(), 8.dp.toPx()),
            strokeWidth = width,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = VeerLime,
            start = Offset(16.dp.toPx(), 4.dp.toPx()),
            end = Offset(20.dp.toPx(), 8.dp.toPx()),
            strokeWidth = width,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = VeerLime,
            start = Offset(20.dp.toPx(), 8.dp.toPx()),
            end = Offset(16.dp.toPx(), 12.dp.toPx()),
            strokeWidth = width,
            cap = StrokeCap.Round,
        )
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF0A0D0C)
@Composable
private fun HomeScreenPreview() {
    VeerTheme {
        HomeScreen(
            state = HomeUiState(),
            onCommandChange = {},
            onApplyCommand = {},
        )
    }
}
