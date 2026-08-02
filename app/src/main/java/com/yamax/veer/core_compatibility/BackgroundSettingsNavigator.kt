package com.yamax.veer.core_compatibility

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings

object BackgroundSettingsNavigator {
    private const val MIUI_AUTOSTART_ACTION = "miui.intent.action.OP_AUTO_START"
    private const val MIUI_BATTERY_ACTION =
        "miui.intent.action.POWER_HIDE_MODE_APP_LIST"
    private const val MIUI_SECURITY_CENTER = "com.miui.securitycenter"
    private const val MIUI_POWER_KEEPER = "com.miui.powerkeeper"

    fun openBatteryAndBackground(context: Context): Boolean {
        val appLabel = runCatching {
            context.applicationInfo.loadLabel(context.packageManager).toString()
        }.getOrDefault("Veer")

        return startFirst(
            context,
            listOf(
                Intent(MIUI_BATTERY_ACTION)
                    .setPackage(MIUI_POWER_KEEPER)
                    .putExtra("package_name", context.packageName)
                    .putExtra("package_label", appLabel),
                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                applicationDetailsIntent(context),
            ),
        )
    }

    fun openAutoStart(context: Context): Boolean = startFirst(
        context,
        listOf(
            Intent(MIUI_AUTOSTART_ACTION).setPackage(MIUI_SECURITY_CENTER),
            applicationDetailsIntent(context),
        ),
    )

    fun openApplicationDetails(context: Context): Boolean =
        startFirst(context, listOf(applicationDetailsIntent(context)))

    private fun applicationDetailsIntent(context: Context): Intent =
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null),
        )

    private fun startFirst(context: Context, intents: List<Intent>): Boolean {
        for (intent in intents) {
            val launched = runCatching {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.isSuccess
            if (launched) return true
        }
        return false
    }
}
