package com.yamax.veer.core_mihomo

/**
 * Pure, stateless classifier that maps a [ClassificationInput] to a [TransitionClassification].
 *
 * Resolution priority (highest to lowest):
 *   CaptivePortal → HealthyHandoff → ValidationFlap → CallbackNoise → TransientLoss/SustainedOutage → Unknown
 *
 * Observability only — no reconnect or recovery logic lives here.
 */
internal object ConnectivityTransitionClassifier {

    private const val TRANSIENT_FAST_MS   = 3_000L
    private const val TRANSIENT_MEDIUM_MS = 10_000L
    private const val SUSTAINED_MS        = 30_000L
    private const val NOISE_BURST_MS      = 200L
    private const val FLAP_CERTAIN_FLIPS  = 3

    fun classify(input: ClassificationInput): TransitionClassification {
        val evidence = collectEvidence(input)
        val (category, confidence) = resolve(input, evidence)
        return TransitionClassification(
            category        = category,
            confidence      = confidence,
            evidenceFlags   = evidence,
            observabilityLog = buildLog(category, confidence, evidence, input),
        )
    }

    // -------------------------------------------------------------------------
    // Evidence collection
    // -------------------------------------------------------------------------

    private fun collectEvidence(input: ClassificationInput): Set<EvidenceFlag> {
        val flags = mutableSetOf<EvidenceFlag>()

        if (input.overlapDurationMs != null)       flags += EvidenceFlag.HAD_OVERLAP
        if (input.transportChanges.isNotEmpty())   flags += EvidenceFlag.HAD_TRANSPORT_CHANGE
        if (input.validatedTransitions > 0)        flags += EvidenceFlag.HAD_VALIDATED_TRANSITION

        val caps = input.events.filterIsInstance<ConnectivityEvent.CapabilitiesChanged>()

        if (input.events.any { it is ConnectivityEvent.Lost && it.remainingCount == 0 })
            flags += EvidenceFlag.HAD_TOTAL_LOSS
        if (caps.any { it.captivePortal })
            flags += EvidenceFlag.HAD_CAPTIVE_PORTAL
        if (input.events.any { it is ConnectivityEvent.BlockedStatusChanged })
            flags += EvidenceFlag.HAD_BLOCKED_STATUS

        val flips = caps.zipWithNext().count { (a, b) ->
            a.networkHandle == b.networkHandle && a.validated != b.validated
        }
        if (flips >= 2) flags += EvidenceFlag.HAD_VALIDATION_FLAP

        if (EvidenceFlag.HAD_TOTAL_LOSS in flags) {
            val ms = recoveryDurationMs(input.events)
            flags += when {
                ms == null || ms >= SUSTAINED_MS -> EvidenceFlag.NO_RECOVERY
                ms < TRANSIENT_FAST_MS           -> EvidenceFlag.RECOVERY_FAST
                ms < TRANSIENT_MEDIUM_MS         -> EvidenceFlag.RECOVERY_MEDIUM
                else                             -> EvidenceFlag.RECOVERY_SLOW
            }
        }

        return flags
    }

    private fun recoveryDurationMs(events: List<ConnectivityEvent>): Long? {
        var lossTs: Long? = null
        for (e in events) {
            if (e is ConnectivityEvent.Lost && e.remainingCount == 0) lossTs = e.timestampMs
            if (e is ConnectivityEvent.Available && lossTs != null) return e.timestampMs - lossTs
        }
        return null
    }

    // -------------------------------------------------------------------------
    // Resolution
    // -------------------------------------------------------------------------

    private fun resolve(
        input: ClassificationInput,
        evidence: Set<EvidenceFlag>,
    ): Pair<TransitionCategory, ClassificationConfidence> {

        // 1. Captive portal — OS flag is authoritative, no ambiguity
        if (EvidenceFlag.HAD_CAPTIVE_PORTAL in evidence)
            return TransitionCategory.CaptivePortalTransition to ClassificationConfidence.Certain

        // 2. Healthy handoff — overlap window with no total-loss gap
        if (EvidenceFlag.HAD_OVERLAP in evidence && EvidenceFlag.HAD_TOTAL_LOSS !in evidence) {
            val confidence = if (EvidenceFlag.HAD_TRANSPORT_CHANGE in evidence)
                ClassificationConfidence.Certain else ClassificationConfidence.Probable
            return TransitionCategory.HealthyHandoff to confidence
        }

        // 3. Validation flap — same-handle validated toggles, no real disconnect
        if (EvidenceFlag.HAD_VALIDATION_FLAP in evidence
            && EvidenceFlag.HAD_TOTAL_LOSS !in evidence
            && EvidenceFlag.HAD_TRANSPORT_CHANGE !in evidence) {
            val flips = countValidationFlips(input)
            val confidence = if (flips >= FLAP_CERTAIN_FLIPS) ClassificationConfidence.Certain
                             else ClassificationConfidence.Probable
            return TransitionCategory.ValidationFlap to confidence
        }

        // 4. Callback noise — no Available/Lost at all, or high-frequency burst of caps events
        val hasRealStateChange = input.events.any {
            it is ConnectivityEvent.Available || it is ConnectivityEvent.Lost
        }
        if (!hasRealStateChange && input.events.isNotEmpty())
            return TransitionCategory.CallbackNoise to ClassificationConfidence.Certain
        if (isNoiseBurst(input))
            return TransitionCategory.CallbackNoise to ClassificationConfidence.Probable

        // 5. Total loss — classify by recovery speed
        if (EvidenceFlag.HAD_TOTAL_LOSS in evidence) {
            return when {
                EvidenceFlag.RECOVERY_FAST   in evidence -> TransitionCategory.TransientLoss   to ClassificationConfidence.Certain
                EvidenceFlag.RECOVERY_MEDIUM in evidence -> TransitionCategory.TransientLoss   to ClassificationConfidence.Probable
                EvidenceFlag.RECOVERY_SLOW   in evidence -> TransitionCategory.TransientLoss   to ClassificationConfidence.Weak
                else                                     -> TransitionCategory.SustainedOutage to ClassificationConfidence.Certain
            }
        }

        return TransitionCategory.Unknown to ClassificationConfidence.Weak
    }

    private fun countValidationFlips(input: ClassificationInput): Int {
        val caps = input.events.filterIsInstance<ConnectivityEvent.CapabilitiesChanged>()
        return caps.zipWithNext().count { (a, b) ->
            a.networkHandle == b.networkHandle && a.validated != b.validated
        }
    }

    private fun isNoiseBurst(input: ClassificationInput): Boolean {
        if (input.timingDeltas.size < 2) return false
        val rapidCount = input.timingDeltas.count { it < NOISE_BURST_MS }
        val capsCount  = input.events.count { it is ConnectivityEvent.CapabilitiesChanged }
        return rapidCount > input.timingDeltas.size / 2
            && capsCount > input.events.size / 2
    }

    // -------------------------------------------------------------------------
    // Observability log
    // -------------------------------------------------------------------------

    private fun buildLog(
        category: TransitionCategory,
        confidence: ClassificationConfidence,
        evidence: Set<EvidenceFlag>,
        input: ClassificationInput,
    ): String {
        val duration = if (input.events.size >= 2)
            input.events.last().timestampMs - input.events.first().timestampMs else 0L
        return buildString {
            append("${category.label} [${confidence.name}]")
            append("  events=${input.events.size} duration=${duration}ms")
            appendLine()
            append("  evidence: ${evidence.joinToString(" ") { it.name }}")
            if (input.transportChanges.isNotEmpty()) {
                appendLine()
                append("  transport: ${input.transportChanges.joinToString(", ") { "${it.first} → ${it.second}" }}")
            }
            if (input.overlapDurationMs != null) {
                appendLine()
                append("  overlap: ${input.overlapDurationMs}ms")
            }
            val recoveryMs = recoveryDurationMs(input.events)
            if (recoveryMs != null) {
                appendLine()
                append("  recovery: ${recoveryMs}ms")
            }
        }
    }
}
