package com.yamax.veer.ui.perapp

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build
import java.util.Locale

internal data class InstalledAppEntry(
    val label: String,
    val packageName: String,
    val isSystemApp: Boolean,
    val isAvailable: Boolean = true,
)

internal object InstalledAppRepository {
    @Suppress("DEPRECATION")
    fun launchableApps(context: Context): List<InstalledAppEntry> {
        val packageManager = context.packageManager
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val activities = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                launcherIntent,
                PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_ALL.toLong()),
            )
        } else {
            packageManager.queryIntentActivities(launcherIntent, PackageManager.MATCH_ALL)
        }

        return activities
            .asSequence()
            .mapNotNull { resolveInfo ->
                val applicationInfo = resolveInfo.activityInfo?.applicationInfo
                    ?: return@mapNotNull null
                val candidatePackage = applicationInfo.packageName
                if (candidatePackage == context.packageName) return@mapNotNull null
                InstalledAppEntry(
                    label = applicationInfo.loadLabel(packageManager)
                        ?.toString()
                        ?.trim()
                        ?.takeIf(String::isNotEmpty)
                        ?: candidatePackage,
                    packageName = candidatePackage,
                    isSystemApp = applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0,
                )
            }
            .distinctBy(InstalledAppEntry::packageName)
            .sortedWith(
                compareBy<InstalledAppEntry> {
                    it.label.lowercase(Locale.getDefault())
                }.thenBy(InstalledAppEntry::packageName),
            )
            .toList()
    }
}
