package com.yamax.veer.ui.nodes

internal data class BatchProbeProgress(
    val total: Int,
    val completed: Int = 0,
    val successful: Int = 0,
    val failed: Int = 0,
) {
    val fraction: Float
        get() = if (total == 0) 0f else completed.toFloat() / total

    fun record(success: Boolean): BatchProbeProgress = copy(
        completed = completed + 1,
        successful = successful + if (success) 1 else 0,
        failed = failed + if (success) 0 else 1,
    )
}

/** Returns each concrete node once even when it appears in multiple groups. */
internal fun uniqueProbeTargets(groups: List<ProxyGroupUi>): List<String> =
    groups.asSequence()
        .flatMap { it.nodes.asSequence() }
        .map(NodeUi::name)
        .distinct()
        .toList()

/** Applies one measurement to every group that references the same node. */
internal fun applyProbeResult(
    groups: List<ProxyGroupUi>,
    nodeName: String,
    delayMs: Int?,
): List<ProxyGroupUi> {
    val alive = delayMs != null && delayMs != UNAVAILABLE_DELAY_MS
    return groups.map { group ->
        group.copy(
            nodes = group.nodes.map { node ->
                if (node.name == nodeName) {
                    node.copy(delayMs = delayMs, alive = alive)
                } else {
                    node
                }
            },
        )
    }
}

internal const val UNAVAILABLE_DELAY_MS = 65_535
