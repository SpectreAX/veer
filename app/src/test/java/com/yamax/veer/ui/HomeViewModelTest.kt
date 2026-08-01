package com.yamax.veer.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class HomeViewModelTest {
    @Test
    fun selectDestinationUpdatesVisibleSection() {
        val viewModel = HomeViewModel()

        viewModel.selectDestination(AppDestination.Rules)

        assertEquals(AppDestination.Rules, viewModel.uiState.value.destination)
    }

    @Test
    fun applyCommandAddsRuleAndClearsInput() {
        val viewModel = HomeViewModel()

        viewModel.updateCommand("Google 走台湾")
        viewModel.applyCommand()

        assertEquals("", viewModel.uiState.value.command)
        assertEquals(1, viewModel.uiState.value.activeRuleCount)
    }

    @Test
    fun applyCommandIgnoresBlankInput() {
        val viewModel = HomeViewModel()

        viewModel.updateCommand("   ")
        viewModel.applyCommand()

        assertEquals(0, viewModel.uiState.value.activeRuleCount)
    }
}
