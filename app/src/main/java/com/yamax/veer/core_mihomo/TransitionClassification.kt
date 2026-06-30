package com.yamax.veer.core_mihomo

/**
 * Output of [ConnectivityTransitionClassifier.classify] for one event window.
 * Contains only observability data — no reconnect or recovery logic.
 */
internal data class TransitionClassification(
    val category: TransitionCategory,
    val confidence: ClassificationConfidence,
    val evidenceFlags: Set<EvidenceFlag>,
    /** Pre-formatted multi-line log string ready for VeerLogger or logcat output. */
    val observabilityLog: String,
)
