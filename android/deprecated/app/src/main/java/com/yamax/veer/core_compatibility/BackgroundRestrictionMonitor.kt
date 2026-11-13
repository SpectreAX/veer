package com.yamax.veer.core_compatibility

import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.PowerManager

object BackgroundRestrictionMonitor {
    fun snapshot(context: Context): BackgroundRestrictionStatus {
        val applicationContext = context.applicationContext
        val powerManager = applicationContext.getSystemService(PowerManager::class.java)
        val activityManager = applicationContext.getSystemService(ActivityManager::class.java)
        val usageStatsManager =
            applicationContext.getSystemService(UsageStatsManager::class.java)

        val signals = BackgroundRestrictionSignals(
            oemFamily = BackgroundRestrictionPolicy.classifyOem(
                manufacturer = Build.MANUFACTURER,
                brand = Build.BRAND,
            ),
            batteryOptimizationExempt = runCatching {
                powerManager?.isIgnoringBatteryOptimizations(
                    applicationContext.packageName,
                ) == true
            }.getOrDefault(false),
            backgroundRestricted = runCatching {
                activityManager?.isBackgroundRestricted == true
            }.getOrDefault(false),
            standbyBucket = runCatching {
                usageStatsManager?.appStandbyBucket.toStandbyBucket()
            }.getOrDefault(AppStandbyBucket.UNKNOWN),
            powerSaveMode = runCatching {
                powerManager?.isPowerSaveMode == true
            }.getOrDefault(false),
        )
        return BackgroundRestrictionPolicy.evaluate(signals)
    }

    private fun Int?.toStandbyBucket(): AppStandbyBucket = when (this) {
        UsageStatsManager.STANDBY_BUCKET_ACTIVE -> AppStandbyBucket.ACTIVE
        UsageStatsManager.STANDBY_BUCKET_WORKING_SET -> AppStandbyBucket.WORKING_SET
        UsageStatsManager.STANDBY_BUCKET_FREQUENT -> AppStandbyBucket.FREQUENT
        UsageStatsManager.STANDBY_BUCKET_RARE -> AppStandbyBucket.RARE
        UsageStatsManager.STANDBY_BUCKET_RESTRICTED -> AppStandbyBucket.RESTRICTED
        else -> AppStandbyBucket.UNKNOWN
    }
}
