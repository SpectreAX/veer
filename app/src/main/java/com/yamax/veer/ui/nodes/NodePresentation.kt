package com.yamax.veer.ui.nodes

import com.yamax.veer.R
import com.yamax.veer.ui.UiText
import com.yamax.veer.ui.uiText

internal enum class DelayQuality {
    UNTESTED,
    FAST,
    MEDIUM,
    SLOW,
    UNAVAILABLE,
}

internal data class DelayPresentation(
    val quality: DelayQuality,
    val text: UiText,
)

internal fun delayPresentation(
    delayMs: Int?,
    alive: Boolean?,
): DelayPresentation = when {
    alive == false || (delayMs != null && delayMs >= UNAVAILABLE_DELAY_MS) ->
        DelayPresentation(DelayQuality.UNAVAILABLE, uiText(R.string.nodes_delay_timeout))
    delayMs == null || delayMs <= 0 ->
        DelayPresentation(DelayQuality.UNTESTED, uiText(R.string.nodes_delay_untested))
    delayMs <= 100 ->
        DelayPresentation(DelayQuality.FAST, uiText(R.string.nodes_delay_ms, delayMs))
    delayMs <= 300 ->
        DelayPresentation(DelayQuality.MEDIUM, uiText(R.string.nodes_delay_ms, delayMs))
    else ->
        DelayPresentation(DelayQuality.SLOW, uiText(R.string.nodes_delay_ms, delayMs))
}
