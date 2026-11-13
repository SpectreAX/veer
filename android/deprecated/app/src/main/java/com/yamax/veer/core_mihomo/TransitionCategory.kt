package com.yamax.veer.core_mihomo

internal sealed class TransitionCategory {
    /** Two or more physical networks briefly overlapped; old network dropped cleanly after new one validated. */
    data object HealthyHandoff : TransitionCategory()

    /** All networks gone briefly (< 10 s) then recovered — likely a roaming bounce or reconnect. */
    data object TransientLoss : TransitionCategory()

    /** All networks gone for an extended period with no recovery observed in the event window. */
    data object SustainedOutage : TransitionCategory()

    /** Network was gated by a captive portal (OS-flagged NET_CAPABILITY_CAPTIVE_PORTAL). */
    data object CaptivePortalTransition : TransitionCategory()

    /** Validated state toggled repeatedly on the same network without an actual disconnect. */
    data object ValidationFlap : TransitionCategory()

    /** High-frequency capability or blocked-status callbacks with no meaningful state change. */
    data object CallbackNoise : TransitionCategory()

    /** Event sequence did not match any known pattern. */
    data object Unknown : TransitionCategory()

    val label: String
        get() = when (this) {
            HealthyHandoff         -> "HealthyHandoff"
            TransientLoss          -> "TransientLoss"
            SustainedOutage        -> "SustainedOutage"
            CaptivePortalTransition -> "CaptivePortalTransition"
            ValidationFlap         -> "ValidationFlap"
            CallbackNoise          -> "CallbackNoise"
            Unknown                -> "Unknown"
        }
}

internal enum class ClassificationConfidence {
    /** Pattern is unambiguous — OS-level flags or structural invariants confirm it. */
    Certain,
    /** Pattern mostly matches but one or more signals are absent or ambiguous. */
    Probable,
    /** Weak match — only partial evidence, alternative categories are plausible. */
    Weak,
}

internal enum class EvidenceFlag {
    HAD_OVERLAP,             // 2+ physical networks were live simultaneously
    HAD_TOTAL_LOSS,          // remainingCount == 0 was observed
    HAD_CAPTIVE_PORTAL,      // NET_CAPABILITY_CAPTIVE_PORTAL was set by OS
    HAD_VALIDATED_TRANSITION, // validated state changed on at least one network
    HAD_TRANSPORT_CHANGE,    // transport type changed across the event window
    HAD_VALIDATION_FLAP,     // validated toggled 2+ times on the same handle
    HAD_BLOCKED_STATUS,      // onBlockedStatusChanged fired at least once
    RECOVERY_FAST,           // total loss recovered in < 3 s
    RECOVERY_MEDIUM,         // total loss recovered in 3–10 s
    RECOVERY_SLOW,           // total loss recovered in 10–30 s
    NO_RECOVERY,             // total loss with no recovery or recovery > 30 s
}
