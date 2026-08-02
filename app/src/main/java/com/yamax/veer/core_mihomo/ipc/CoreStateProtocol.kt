package com.yamax.veer.core_mihomo.ipc

import android.net.Uri
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.StartupStage

internal data class CoreRuntimeSnapshot(
    val engineState: EngineState,
    val startupStage: StartupStage,
    val physicalNetworksAvailable: Int,
    val hasInternet: Boolean,
    val processId: Int,
)

internal data class CoreTrafficSnapshot(
    val uploadTotal: Long,
    val downloadTotal: Long,
    val activeConnections: Int,
)

internal data class CoreDashboardRoutingSnapshot(
    val coreRunning: Boolean,
    val mode: String,
    val policy: String?,
    val selectedNode: String?,
    val nodeDelayMs: Int?,
)

internal data class CoreReloadResult(
    val success: Boolean,
    val status: Int,
    val message: String,
)

internal object CoreStateProtocol {
    const val AUTHORITY = "com.yamax.veer.core.state"
    val URI: Uri get() = Uri.parse("content://$AUTHORITY/runtime")

    const val METHOD_RUNTIME = "runtime"
    const val METHOD_TRAFFIC = "traffic"
    const val METHOD_DASHBOARD = "dashboard"
    const val METHOD_LOGS = "logs"
    const val METHOD_RELOAD_RULES = "reload_rules"

    const val KEY_ENGINE_KIND = "engine_kind"
    const val KEY_ENGINE_ERROR = "engine_error"
    const val KEY_STARTUP_STAGE = "startup_stage"
    const val KEY_PHYSICAL_NETWORKS = "physical_networks"
    const val KEY_HAS_INTERNET = "has_internet"
    const val KEY_PROCESS_ID = "process_id"
    const val KEY_DEFAULT_POLICY = "default_policy"
    const val KEY_UPLOAD_TOTAL = "upload_total"
    const val KEY_DOWNLOAD_TOTAL = "download_total"
    const val KEY_ACTIVE_CONNECTIONS = "active_connections"
    const val KEY_CORE_RUNNING = "core_running"
    const val KEY_MODE = "mode"
    const val KEY_POLICY = "policy"
    const val KEY_SELECTED_NODE = "selected_node"
    const val KEY_NODE_DELAY_MS = "node_delay_ms"
    const val KEY_LOG_LIMIT = "log_limit"
    const val KEY_LOG_LINES = "log_lines"
    const val KEY_CONFIG_DIRECTORY = "config_directory"
    const val KEY_CONFIG_FILE = "config_file"
    const val KEY_SUCCESS = "success"
    const val KEY_STATUS = "status"
    const val KEY_MESSAGE = "message"
    const val UNKNOWN_DELAY_MS = -1

    fun engineKind(state: EngineState): String = when (state) {
        EngineState.Stopped -> "stopped"
        EngineState.Starting -> "starting"
        EngineState.Running -> "running"
        EngineState.Stopping -> "stopping"
        is EngineState.Error -> "error"
    }

    fun decodeEngineState(kind: String?, error: String?): EngineState = when (kind) {
        "starting" -> EngineState.Starting
        "running" -> EngineState.Running
        "stopping" -> EngineState.Stopping
        "error" -> EngineState.Error(error.orEmpty().ifBlank { "core process error" })
        else -> EngineState.Stopped
    }

    fun decodeStartupStage(value: String?): StartupStage =
        value
            ?.let { name -> StartupStage.entries.firstOrNull { it.name == name } }
            ?: StartupStage.IDLE
}
