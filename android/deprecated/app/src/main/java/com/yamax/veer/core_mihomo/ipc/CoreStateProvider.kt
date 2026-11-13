package com.yamax.veer.core_mihomo.ipc

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Process
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.VeercoreNativeExecutor
import veercore.Veercore
import java.io.File

/**
 * Same-UID IPC endpoint hosted beside [com.yamax.veer.core_mihomo.VeerVpnService]
 * in `:veercore`. No profile, subscription, rule or credential data is exposed.
 */
internal class CoreStateProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle = when (method) {
        CoreStateProtocol.METHOD_RUNTIME -> runtimeSnapshot()
        CoreStateProtocol.METHOD_TRAFFIC -> trafficSnapshot()
        CoreStateProtocol.METHOD_DASHBOARD -> dashboardSnapshot(
            extras?.getString(CoreStateProtocol.KEY_DEFAULT_POLICY).orEmpty(),
        )
        CoreStateProtocol.METHOD_LOGS -> logSnapshot(
            extras?.getInt(CoreStateProtocol.KEY_LOG_LIMIT, 200) ?: 200,
        )
        CoreStateProtocol.METHOD_RELOAD_RULES -> reloadRules(extras)
        else -> Bundle.EMPTY
    }

    private fun runtimeSnapshot(): Bundle {
        val engine = MihomoEngine.state.value
        val status = MihomoEngine.status.value
        val appState = AppStateRepository.appState.value
        return Bundle().apply {
            putString(CoreStateProtocol.KEY_ENGINE_KIND, CoreStateProtocol.engineKind(engine))
            putString(
                CoreStateProtocol.KEY_ENGINE_ERROR,
                (engine as? com.yamax.veer.core_mihomo.EngineState.Error)?.message,
            )
            putString(CoreStateProtocol.KEY_STARTUP_STAGE, MihomoEngine.startupStage.value.name)
            putLong(CoreStateProtocol.KEY_STATE_TIMESTAMP, status.timestampMs)
            putString(CoreStateProtocol.KEY_OPERATION_ID, status.operationId)
            putString(CoreStateProtocol.KEY_STATE_MESSAGE, status.message)
            putString(CoreStateProtocol.KEY_MACHINE_CODE, status.machineCode)
            putString(CoreStateProtocol.KEY_ROOT_CAUSE, status.rootCause)
            putString(CoreStateProtocol.KEY_RECOVERABILITY, status.recoverability.name)
            putInt(
                CoreStateProtocol.KEY_PHYSICAL_NETWORKS,
                appState.connectivity.physicalNetworksAvailable,
            )
            putBoolean(CoreStateProtocol.KEY_HAS_INTERNET, appState.connectivity.hasInternet)
            putInt(CoreStateProtocol.KEY_PROCESS_ID, Process.myPid())
        }
    }

    private fun trafficSnapshot(): Bundle {
        val stats = VeercoreNativeExecutor.call { Veercore.getTrafficStats() }
        return Bundle().apply {
            putLong(CoreStateProtocol.KEY_UPLOAD_TOTAL, stats.uploadTotal)
            putLong(CoreStateProtocol.KEY_DOWNLOAD_TOTAL, stats.downloadTotal)
            putInt(CoreStateProtocol.KEY_ACTIVE_CONNECTIONS, stats.activeConnections)
        }
    }

    private fun dashboardSnapshot(defaultPolicy: String): Bundle {
        val stats = VeercoreNativeExecutor.call {
            Veercore.getDashboardRoutingStats(defaultPolicy)
        }
        return Bundle().apply {
            putBoolean(CoreStateProtocol.KEY_CORE_RUNNING, stats.coreRunning)
            putString(CoreStateProtocol.KEY_MODE, stats.mode)
            putString(CoreStateProtocol.KEY_POLICY, stats.policy)
            putString(CoreStateProtocol.KEY_SELECTED_NODE, stats.selectedNode)
            putInt(CoreStateProtocol.KEY_NODE_DELAY_MS, stats.nodeDelayMs)
        }
    }

    private fun logSnapshot(limit: Int): Bundle = Bundle().apply {
        putStringArrayList(
            CoreStateProtocol.KEY_LOG_LINES,
            ArrayList(VeerLog.formattedRingSnapshot(limit)),
        )
    }

    private fun reloadRules(extras: Bundle?): Bundle {
        val directory = extras?.getString(CoreStateProtocol.KEY_CONFIG_DIRECTORY).orEmpty()
        val fileName = extras?.getString(CoreStateProtocol.KEY_CONFIG_FILE).orEmpty()
        val filesRoot = requireNotNull(context).filesDir.canonicalFile
        val configDirectory = runCatching { File(directory).canonicalFile }.getOrNull()
        val safeDirectory = configDirectory != null &&
            (configDirectory == filesRoot ||
                configDirectory.path.startsWith(filesRoot.path + File.separator))
        val safeName = fileName.isNotBlank() &&
            fileName == File(fileName).name &&
            !fileName.contains(File.separatorChar)
        if (!safeDirectory || !safeName) {
            return reloadResult(false, -1, "rejected config path outside app storage")
        }
        if (MihomoEngine.state.value !is EngineState.Running) {
            return reloadResult(false, -1, "core is not running")
        }
        return runCatching {
            VeercoreNativeExecutor.call {
                Veercore.reloadRules(configDirectory.path, fileName)
            }
            requireNotNull(context).contentResolver.notifyChange(CoreStateProtocol.URI, null)
            reloadResult(true, 0, "native rules reload complete")
        }.getOrElse {
            reloadResult(false, -1, it.message ?: "native reload error")
        }
    }

    private fun reloadResult(success: Boolean, status: Int, message: String): Bundle =
        Bundle().apply {
            putBoolean(CoreStateProtocol.KEY_SUCCESS, success)
            putInt(CoreStateProtocol.KEY_STATUS, status)
            putString(CoreStateProtocol.KEY_MESSAGE, message)
        }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
