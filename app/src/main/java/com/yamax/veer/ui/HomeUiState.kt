package com.yamax.veer.ui

import com.yamax.veer.core.EngineState

data class HomeUiState(
    val destination: AppDestination = AppDestination.Home,
    val engineState: EngineState = EngineState.Stopped,
    val command: String = "",
    val activeRuleCount: Int = 0,
    val profileName: String = "尚未导入配置",
    val isRuntimeAvailable: Boolean = false,
)
