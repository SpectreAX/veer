package com.yamax.veer.testing

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.ui.logs.LogSource
import com.yamax.veer.ui.logs.LogViewerRepository
import java.io.File

/** Debug-only hook that verifies the VPN/core process survives main-process death. */
class DebugUiProcessReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_KILL_UI_PROCESS -> {
                val pid = Process.myPid()
                Log.w(TAG, "killing UI process pid=$pid for isolation verification")
                Handler(Looper.getMainLooper()).post {
                    Process.killProcess(pid)
                }
            }
            ACTION_DUMP_LOG_VIEWER -> {
                val fakeKey = "sk-viewer-redaction-test-1234567890"
                val fakeUrl = "https://example.invalid/private?token=viewer-test"
                VeerLog.ui("viewer probe key=$fakeKey url=$fakeUrl")
                val lines = LogViewerRepository().snapshot()
                val rendered = lines.joinToString("\n") { it.formatted() }
                File(context.filesDir, LOG_VIEWER_OUTPUT_FILE).writeText(
                    buildString {
                        append("total=${lines.size}\n")
                        append("ui=${lines.count { it.source == LogSource.UI }}\n")
                        append("core=${lines.count { it.source == LogSource.CORE }}\n")
                        append("redacted=${fakeKey !in rendered && fakeUrl !in rendered}\n")
                    },
                )
                Log.i(TAG, "log viewer snapshot lines=${lines.size}")
            }
        }
    }

    companion object {
        const val ACTION_KILL_UI_PROCESS = "com.yamax.veer.debug.KILL_UI_PROCESS"
        const val ACTION_DUMP_LOG_VIEWER = "com.yamax.veer.debug.DUMP_LOG_VIEWER"
        const val LOG_VIEWER_OUTPUT_FILE = "debug_log_viewer.txt"
        private const val TAG = "VeerDebugUi"
    }
}
