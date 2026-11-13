package com.yamax.veer.ui

import androidx.annotation.StringRes
import com.yamax.veer.R
import com.yamax.veer.core_mihomo.EngineState

internal enum class HomePrimaryAction {
    IMPORT_PROFILE,
    START,
    STARTING,
    STOP,
    STOPPING,
    RECOVER_ERROR,
}

internal data class HomePrimaryActionUi(
    val action: HomePrimaryAction,
    @param:StringRes val labelRes: Int,
    val enabled: Boolean,
)

internal fun homePrimaryAction(
    engineState: EngineState,
    hasActiveProfile: Boolean,
): HomePrimaryActionUi {
    if (!hasActiveProfile) {
        return HomePrimaryActionUi(
            action = HomePrimaryAction.IMPORT_PROFILE,
            labelRes = R.string.home_action_import_profile,
            enabled = engineState is EngineState.Stopped,
        )
    }

    return when (engineState) {
        is EngineState.Stopped -> HomePrimaryActionUi(
            HomePrimaryAction.START,
            R.string.home_action_start,
            true,
        )
        is EngineState.Starting -> HomePrimaryActionUi(
            HomePrimaryAction.STARTING,
            R.string.home_action_starting,
            false,
        )
        is EngineState.Running -> HomePrimaryActionUi(
            HomePrimaryAction.STOP,
            R.string.home_action_stop,
            true,
        )
        is EngineState.Stopping -> HomePrimaryActionUi(
            HomePrimaryAction.STOPPING,
            R.string.home_action_stopping,
            false,
        )
        is EngineState.Error -> HomePrimaryActionUi(
            HomePrimaryAction.RECOVER_ERROR,
            R.string.home_action_recover_error,
            true,
        )
    }
}

internal enum class AiExecutionReadiness {
    NO_PROFILE,
    VPN_NOT_RUNNING,
    LOCAL_ONLY,
    READY,
}

internal fun aiExecutionReadiness(
    engineState: EngineState,
    hasActiveProfile: Boolean,
    hasApiKey: Boolean,
): AiExecutionReadiness = when {
    !hasActiveProfile -> AiExecutionReadiness.NO_PROFILE
    engineState !is EngineState.Running -> AiExecutionReadiness.VPN_NOT_RUNNING
    !hasApiKey -> AiExecutionReadiness.LOCAL_ONLY
    else -> AiExecutionReadiness.READY
}

internal val AiExecutionReadiness.canExecute: Boolean
    get() = this == AiExecutionReadiness.LOCAL_ONLY || this == AiExecutionReadiness.READY

@StringRes
internal fun AiExecutionReadiness.guidanceRes(): Int = when (this) {
    AiExecutionReadiness.NO_PROFILE -> R.string.ai_readiness_no_profile
    AiExecutionReadiness.VPN_NOT_RUNNING -> R.string.ai_readiness_vpn_stopped
    AiExecutionReadiness.LOCAL_ONLY -> R.string.ai_readiness_local_only
    AiExecutionReadiness.READY -> R.string.ai_readiness_ready
}
