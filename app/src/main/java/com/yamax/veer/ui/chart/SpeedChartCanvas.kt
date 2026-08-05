package com.yamax.veer.ui.chart

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.res.stringResource
import com.yamax.veer.R
import com.yamax.veer.data.SpeedSample
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.designsystem.theme.VeerDimensions
import com.yamax.veer.ui.designsystem.theme.VeerSpacing
import java.util.Locale

internal const val SPEED_CHART_MAX_POINTS = 60

fun formatSpeed(bytesPerSec: Long): String {
    val safeSpeed = bytesPerSec.coerceAtLeast(0L)
    if (safeSpeed < 1_024) return "$safeSpeed B/s"
    val kb = safeSpeed / 1_024.0
    if (kb < 1_024) return String.format(Locale.ROOT, "%.1f KB/s", kb)
    val mb = kb / 1_024.0
    if (mb < 1_024) return String.format(Locale.ROOT, "%.1f MB/s", mb)
    val gb = mb / 1_024.0
    return String.format(Locale.ROOT, "%.1f GB/s", gb)
}

@Composable
fun SpeedChart(
    history: List<SpeedSample>,
    connected: Boolean,
    modifier: Modifier = Modifier,
) {
    val visibleHistory = history.takeLast(SPEED_CHART_MAX_POINTS)
    val currentUp = visibleHistory.lastOrNull()?.uploadSpeed ?: 0L
    val currentDown = visibleHistory.lastOrNull()?.downloadSpeed ?: 0L
    val uploadColor = MaterialTheme.colorScheme.primary
    val downloadColor = MaterialTheme.colorScheme.tertiary
    val guideColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.30f)
    val statusText = when {
        !connected -> stringResource(R.string.speed_chart_disconnected)
        visibleHistory.isEmpty() -> stringResource(R.string.speed_chart_waiting)
        else -> null
    }
    val accessibilityDescription = if (connected) {
        stringResource(
            R.string.speed_chart_accessibility_connected,
            formatSpeed(currentUp),
            formatSpeed(currentDown),
        )
    } else {
        stringResource(R.string.speed_chart_accessibility_disconnected)
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(VeerDimensions.speedChartHeight)
            .testTag("speed_chart")
            .semantics { contentDescription = accessibilityDescription },
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val dataTop = VeerSpacing.xl.toPx()
            val dataBottom = size.height - VeerSpacing.xl.toPx()
            val dataHeight = (dataBottom - dataTop).coerceAtLeast(1f)

            drawLine(
                color = guideColor,
                start = Offset(0f, dataBottom),
                end = Offset(size.width, dataBottom),
                strokeWidth = VeerDimensions.progressStroke.toPx(),
                cap = StrokeCap.Round,
            )

            if (!connected || visibleHistory.isEmpty()) return@Canvas

            val maxSpeed = visibleHistory
                .maxOf { maxOf(it.uploadSpeed, it.downloadSpeed) }
                .coerceAtLeast(1_024L)
            val stepX = size.width / (SPEED_CHART_MAX_POINTS - 1)
            val startIndex = SPEED_CHART_MAX_POINTS - visibleHistory.size

            fun point(index: Int, speed: Long): Offset {
                val x = (startIndex + index) * stepX
                val ratio = speed.coerceAtLeast(0L).toFloat() / maxSpeed.toFloat()
                return Offset(x, dataBottom - ratio.coerceIn(0f, 1f) * dataHeight)
            }

            fun drawSeries(
                speeds: List<Long>,
                color: Color,
            ) {
                val linePath = Path()
                .apply {
                    speeds.forEachIndexed { index, speed ->
                        val point = point(index, speed)
                        if (index == 0) moveTo(point.x, point.y) else lineTo(point.x, point.y)
                    }
                }
                val first = point(0, speeds.first())
                val last = point(speeds.lastIndex, speeds.last())
                val fillPath = Path().apply {
                    moveTo(first.x, dataBottom)
                    lineTo(first.x, first.y)
                    speeds.drop(1).forEachIndexed { index, speed ->
                        val point = point(index + 1, speed)
                        lineTo(point.x, point.y)
                    }
                    lineTo(last.x, dataBottom)
                    close()
                }

                drawPath(
                    path = fillPath,
                    brush = Brush.verticalGradient(
                        colors = listOf(color.copy(alpha = 0.18f), Color.Transparent),
                        startY = dataTop,
                        endY = dataBottom,
                    ),
                )
                drawPath(
                    path = linePath,
                    color = color,
                    style = Stroke(
                        width = VeerDimensions.progressStroke.toPx(),
                        cap = StrokeCap.Round,
                    ),
                )
                drawCircle(
                    color = color,
                    radius = VeerDimensions.chartPointRadius.toPx(),
                    center = last,
                )
            }

            drawSeries(visibleHistory.map(SpeedSample::uploadSpeed), uploadColor)
            drawSeries(visibleHistory.map(SpeedSample::downloadSpeed), downloadColor)
        }

        if (statusText != null) {
            Text(
                text = statusText,
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.align(Alignment.Center),
            )
        } else {
            Text(
                text = stringResource(
                    R.string.speed_chart_current,
                    formatSpeed(currentUp),
                    formatSpeed(currentDown),
                ),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(horizontal = VeerSpacing.sm, vertical = VeerSpacing.xs),
            )
        }

        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(horizontal = VeerSpacing.sm, vertical = VeerSpacing.xxs),
        ) {
            TimeAxisLabel(stringResource(R.string.speed_chart_60_seconds))
            Spacer(modifier = Modifier.weight(1f))
            TimeAxisLabel(stringResource(R.string.speed_chart_30_seconds))
            Spacer(modifier = Modifier.weight(1f))
            TimeAxisLabel(stringResource(R.string.speed_chart_now))
        }
    }
}

@VeerThemePreviews
@Composable
private fun SpeedChartPreview() {
    VeerPreview {
        SpeedChart(
            history = listOf(
                SpeedSample(timestamp = 1, uploadSpeed = 32_768, downloadSpeed = 120_000),
                SpeedSample(timestamp = 2, uploadSpeed = 64_000, downloadSpeed = 800_000),
                SpeedSample(timestamp = 3, uploadSpeed = 48_000, downloadSpeed = 360_000),
                SpeedSample(timestamp = 4, uploadSpeed = 96_000, downloadSpeed = 1_200_000),
            ),
            connected = true,
            modifier = Modifier.padding(VeerSpacing.lg),
        )
    }
}

@Composable
private fun TimeAxisLabel(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}
