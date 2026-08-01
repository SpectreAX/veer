package com.yamax.veer.core_compatibility

enum class OemFamily {
    XIAOMI,
    OTHER,
}
enum class AppStandbyBucket {
    ACTIVE,
    WORKING_SET,
    FREQUENT,
    RARE,
    RESTRICTED,
    UNKNOWN,
}

enum class BackgroundRisk {
    READY,
    ATTENTION,
    RESTRICTED,
}

data class BackgroundRestrictionSignals(
    val oemFamily: OemFamily,
    val batteryOptimizationExempt: Boolean,
    val backgroundRestricted: Boolean,
    val standbyBucket: AppStandbyBucket,
    val powerSaveMode: Boolean,
)

data class BackgroundRestrictionStatus(
    val risk: BackgroundRisk,
    val oemFamily: OemFamily,
    val batteryOptimizationExempt: Boolean,
    val backgroundRestricted: Boolean,
    val standbyBucket: AppStandbyBucket,
    val powerSaveMode: Boolean,
    val reasons: List<BackgroundRestrictionReason>,
) {
    val shouldShow: Boolean
        get() = risk != BackgroundRisk.READY

    val needsOemReview: Boolean
        get() = oemFamily == OemFamily.XIAOMI
}

enum class BackgroundRestrictionReason {
    SYSTEM_BACKGROUND_RESTRICTED,
    STANDBY_RESTRICTED,
    STANDBY_RARE,
    BATTERY_OPTIMIZATION_ENABLED,
    POWER_SAVE_MODE,
    XIAOMI_SETTINGS_UNVERIFIABLE,
}

object BackgroundRestrictionPolicy {
    fun evaluate(signals: BackgroundRestrictionSignals): BackgroundRestrictionStatus {
        val reasons = buildList {
            if (signals.backgroundRestricted) {
                add(BackgroundRestrictionReason.SYSTEM_BACKGROUND_RESTRICTED)
            }
            when (signals.standbyBucket) {
                AppStandbyBucket.RESTRICTED ->
                    add(BackgroundRestrictionReason.STANDBY_RESTRICTED)
                AppStandbyBucket.RARE ->
                    add(BackgroundRestrictionReason.STANDBY_RARE)
                else -> Unit
            }
            if (!signals.batteryOptimizationExempt) {
                add(BackgroundRestrictionReason.BATTERY_OPTIMIZATION_ENABLED)
            }
            if (signals.powerSaveMode) {
                add(BackgroundRestrictionReason.POWER_SAVE_MODE)
            }
            if (signals.oemFamily == OemFamily.XIAOMI) {
                // MIUI/HyperOS does not expose a supported API for its
                // autostart and per-app battery policy. Keep this as a manual
                // review instead of claiming a state Veer cannot observe.
                add(BackgroundRestrictionReason.XIAOMI_SETTINGS_UNVERIFIABLE)
            }
        }

        val risk = when {
            signals.backgroundRestricted ||
                signals.standbyBucket == AppStandbyBucket.RESTRICTED ->
                BackgroundRisk.RESTRICTED
            reasons.isNotEmpty() -> BackgroundRisk.ATTENTION
            else -> BackgroundRisk.READY
        }

        return BackgroundRestrictionStatus(
            risk = risk,
            oemFamily = signals.oemFamily,
            batteryOptimizationExempt = signals.batteryOptimizationExempt,
            backgroundRestricted = signals.backgroundRestricted,
            standbyBucket = signals.standbyBucket,
            powerSaveMode = signals.powerSaveMode,
            reasons = reasons,
        )
    }

    fun classifyOem(manufacturer: String?, brand: String?): OemFamily {
        val identifiers = listOf(manufacturer, brand)
            .mapNotNull { it?.trim()?.lowercase() }
        return if (identifiers.any { value ->
                value == "xiaomi" ||
                    value == "redmi" ||
                    value == "poco"
            }
        ) {
            OemFamily.XIAOMI
        } else {
            OemFamily.OTHER
        }
    }
}
