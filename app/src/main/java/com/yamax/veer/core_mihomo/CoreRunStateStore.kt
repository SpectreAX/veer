package com.yamax.veer.core_mihomo

import android.content.Context
import java.io.File

/**
 * Cross-process marker for the user's requested VPN state.
 *
 * A file is used instead of SharedPreferences because Android does not provide
 * coherent multi-process SharedPreferences caches. Creating/deleting the marker
 * makes every process observe the latest value without retaining credentials or
 * profile data.
 */
internal object CoreRunStateStore {
    private const val MARKER_NAME = "veer_core_desired_running"

    fun setDesiredRunning(context: Context, desiredRunning: Boolean) {
        val marker = marker(context)
        runCatching {
            if (desiredRunning) {
                if (!marker.exists()) {
                    marker.writeText("1")
                }
            } else {
                marker.delete()
            }
        }
    }

    fun isDesiredRunning(context: Context): Boolean = marker(context).isFile

    private fun marker(context: Context): File =
        File(context.applicationContext.noBackupFilesDir, MARKER_NAME)
}
