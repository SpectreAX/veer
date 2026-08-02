package com.yamax.veer.ui

import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

class HomeViewModel : ViewModel() {
    private val _uiState = MutableStateFlow(HomeUiState())
    val uiState: StateFlow<HomeUiState> = _uiState.asStateFlow()

    fun selectDestination(destination: AppDestination) {
        _uiState.update { it.copy(destination = destination) }
    }

    fun updateCommand(value: String) {
        _uiState.update { it.copy(command = value) }
    }

    fun applyCommand() {
        val command = _uiState.value.command.trim()
        if (command.isEmpty()) return

        _uiState.update {
            it.copy(
                command = "",
                activeRuleCount = it.activeRuleCount + 1,
            )
        }
    }
}
