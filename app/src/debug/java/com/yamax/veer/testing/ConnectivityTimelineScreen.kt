@file:OptIn(ExperimentalMaterial3Api::class)

package com.yamax.veer.testing

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.yamax.veer.core_mihomo.ClassificationConfidence
import com.yamax.veer.core_mihomo.ConnectivityEvent
import com.yamax.veer.core_mihomo.TransitionCategory
import kotlinx.coroutines.delay

@Composable
fun ConnectivityTimelineScreen() {
    var events by remember { mutableStateOf(ConnectivityTrace.peek()) }
    var selectedTab by remember { mutableStateOf(0) }
    var filterHandle by remember { mutableStateOf<Long?>(null) }
    val context = LocalContext.current

    LaunchedEffect(Unit) {
        while (true) {
            events = ConnectivityTrace.peek()
            delay(500)
        }
    }

    val allHandles = remember(events) { events.map { it.networkHandle }.distinct().sorted() }
    val filteredEvents = remember(events, filterHandle) {
        if (filterHandle == null) events else events.filter { it.networkHandle == filterHandle }
    }
    val summaries = remember(filteredEvents) {
        ConnectivityTraceReplayer.replay(filteredEvents)
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("Connectivity Timeline") }) },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            HandleFilterRow(
                handles = allHandles,
                selected = filterHandle,
                onSelect = { filterHandle = if (filterHandle == it) null else it },
            )

            val tabs = listOf(
                "Raw (${filteredEvents.size})",
                "Classified (${summaries.size})",
                "Timeline",
            )
            TabRow(selectedTabIndex = selectedTab) {
                tabs.forEachIndexed { i, title ->
                    Tab(
                        selected = selectedTab == i,
                        onClick = { selectedTab = i },
                        text = { Text(title) },
                    )
                }
            }

            Box(modifier = Modifier.weight(1f)) {
                when (selectedTab) {
                    0 -> RawEventsTab(filteredEvents)
                    1 -> ClassifiedTab(summaries)
                    2 -> TimelineTab(filteredEvents, filterHandle)
                }
            }

            DebugActionsBar(
                onClear = {
                    ConnectivityTrace.clear()
                    events = emptyList()
                },
                onSnapshot = { events = ConnectivityTrace.peek() },
                onDump = {
                    val report = ConnectivityTrace.dump() +
                        "\n\n" + ConnectivityTraceReplayer.dumpReport(events)
                    shareText(context, report)
                },
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Handle filter row
// ---------------------------------------------------------------------------

@Composable
private fun HandleFilterRow(
    handles: List<Long>,
    selected: Long?,
    onSelect: (Long) -> Unit,
) {
    if (handles.isEmpty()) return
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Handle:", style = MaterialTheme.typography.labelMedium)
        handles.forEach { handle ->
            FilterChip(
                selected = selected == handle,
                onClick = { onSelect(handle) },
                label = {
                    Text("net#$handle", style = MaterialTheme.typography.labelSmall)
                },
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Tab: Raw events
// ---------------------------------------------------------------------------

@Composable
private fun RawEventsTab(events: List<ConnectivityEvent>) {
    if (events.isEmpty()) {
        EmptyState("No events recorded.\nTrigger a network change while the VPN is running.")
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        itemsIndexed(events) { i, event ->
            val delta = if (i == 0) 0L else event.timestampMs - events[i - 1].timestampMs
            RawEventRow(event, delta)
        }
    }
}

@Composable
private fun RawEventRow(event: ConnectivityEvent, deltaMs: Long) {
    val (typeLabel, typeColor) = when (event) {
        is ConnectivityEvent.Available          -> "AVAIL" to Color(0xFF4CAF50)
        is ConnectivityEvent.Lost               -> "LOST " to Color(0xFFF44336)
        is ConnectivityEvent.CapabilitiesChanged  -> "CAPS " to Color(0xFF2196F3)
        is ConnectivityEvent.BlockedStatusChanged -> "BLOCK" to Color(0xFFFF9800)
    }
    val detail = when (event) {
        is ConnectivityEvent.Available ->
            "net#${event.networkHandle}  ${event.transports}  ${if (event.validated) "VAL" else "unv"}"
        is ConnectivityEvent.Lost ->
            "net#${event.networkHandle}  rem=${event.remainingCount}"
        is ConnectivityEvent.CapabilitiesChanged -> {
            val cp = if (event.captivePortal) " CAPTIVE" else ""
            "net#${event.networkHandle}  ${event.transports}  ${if (event.validated) "VAL" else "unv"}$cp"
        }
        is ConnectivityEvent.BlockedStatusChanged ->
            "net#${event.networkHandle}  ${if (event.blocked) "BLOCKED" else "unblocked"}"
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(4.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = typeLabel,
            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
            color = typeColor,
            modifier = Modifier.width(44.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = detail,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
            )
            Text(
                text = "+${deltaMs}ms  [${event.threadName}]",
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Tab: Classified windows
// ---------------------------------------------------------------------------

@Composable
private fun ClassifiedTab(summaries: List<TransitionSummary>) {
    if (summaries.isEmpty()) {
        EmptyState("No events to classify.\nCollect some network events first.")
        return
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(summaries) { s -> ClassifiedWindowCard(s) }
    }
}

@Composable
private fun ClassifiedWindowCard(summary: TransitionSummary) {
    val c = summary.classification
    val confidenceColor = when (c.confidence) {
        ClassificationConfidence.Certain  -> Color(0xFF4CAF50)
        ClassificationConfidence.Probable -> Color(0xFFFF9800)
        ClassificationConfidence.Weak     -> Color(0xFFF44336)
    }
    val categoryColor = when (c.category) {
        is TransitionCategory.HealthyHandoff          -> Color(0xFF4CAF50)
        is TransitionCategory.TransientLoss           -> Color(0xFFFF9800)
        is TransitionCategory.SustainedOutage         -> Color(0xFFF44336)
        is TransitionCategory.CaptivePortalTransition -> Color(0xFF9C27B0)
        is TransitionCategory.ValidationFlap          -> Color(0xFF2196F3)
        is TransitionCategory.CallbackNoise           -> Color(0xFF607D8B)
        is TransitionCategory.Unknown                 -> Color(0xFF9E9E9E)
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = c.category.label,
                    style = MaterialTheme.typography.titleSmall,
                    color = categoryColor,
                )
                Text(
                    text = c.confidence.name,
                    style = MaterialTheme.typography.labelSmall,
                    color = confidenceColor,
                )
            }
            Text(
                text = "Window ${summary.windowIndex}  •  ${summary.windowDurationMs}ms  •  ${summary.eventCount} events",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (c.evidenceFlags.isNotEmpty()) {
                Text(
                    text = c.evidenceFlags.joinToString(" ") { it.name },
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tab: Timeline visual
// ---------------------------------------------------------------------------

@Composable
private fun TimelineTab(events: List<ConnectivityEvent>, focusHandle: Long?) {
    if (events.isEmpty()) {
        EmptyState("No events to visualize.")
        return
    }

    val handles = remember(events) { events.map { it.networkHandle }.distinct().sorted() }
    val minTs = events.first().timestampMs
    val maxTs = events.last().timestampMs
    val spanMs = (maxTs - minTs).coerceAtLeast(1L)

    // Active intervals per handle: [startMs, endMs?]
    data class Interval(val handle: Long, val startMs: Long, val endMs: Long?)
    // CapabilitiesChanged markers
    data class CapsMarker(val handle: Long, val timestampMs: Long, val validated: Boolean, val captivePortal: Boolean)
    // Overlap windows
    data class OverlapInterval(val startMs: Long, val endMs: Long)

    val intervals = remember(events) {
        val result = mutableListOf<Interval>()
        val openAt = mutableMapOf<Long, Long>()
        for (e in events) {
            when (e) {
                is ConnectivityEvent.Available -> openAt[e.networkHandle] = e.timestampMs
                is ConnectivityEvent.Lost -> {
                    val start = openAt.remove(e.networkHandle)
                    if (start != null) result += Interval(e.networkHandle, start, e.timestampMs)
                }
                else -> {}
            }
        }
        // Still-active at end of trace
        openAt.forEach { (h, start) -> result += Interval(h, start, null) }
        result
    }

    val capsMarkers = remember(events) {
        events.filterIsInstance<ConnectivityEvent.CapabilitiesChanged>().map {
            CapsMarker(it.networkHandle, it.timestampMs, it.validated, it.captivePortal)
        }
    }

    val overlapIntervals = remember(events) {
        val active = mutableSetOf<Long>()
        var overlapStart: Long? = null
        val result = mutableListOf<OverlapInterval>()
        for (e in events) {
            when (e) {
                is ConnectivityEvent.Available -> {
                    active.add(e.networkHandle)
                    if (active.size >= 2 && overlapStart == null) overlapStart = e.timestampMs
                }
                is ConnectivityEvent.Lost -> {
                    active.remove(e.networkHandle)
                    if (active.size < 2 && overlapStart != null) {
                        result += OverlapInterval(overlapStart!!, e.timestampMs)
                        overlapStart = null
                    }
                }
                else -> {}
            }
        }
        if (overlapStart != null && active.size >= 2) result += OverlapInterval(overlapStart!!, maxTs)
        result
    }

    val laneHeightDp = 36.dp
    val labelWidthDp = 80.dp
    val timelineWidthDp = 600.dp
    // +1 for the overlap summary lane at the top
    val canvasHeightDp = laneHeightDp * (handles.size + 1)

    val density = LocalDensity.current
    val laneH = with(density) { laneHeightDp.toPx() }
    val timelineW = with(density) { timelineWidthDp.toPx() }

    fun timeToX(ts: Long): Float = ((ts - minTs).toFloat() / spanMs) * timelineW

    Column(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
        // Lanes: label column + scrollable canvas side by side
        Row(modifier = Modifier.height(canvasHeightDp).fillMaxWidth()) {
            // Lane labels
            Column(modifier = Modifier.width(labelWidthDp)) {
                Box(
                    modifier = Modifier.height(laneHeightDp).fillMaxWidth().padding(horizontal = 6.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Text(
                        text = "overlap",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                handles.forEach { handle ->
                    Box(
                        modifier = Modifier.height(laneHeightDp).fillMaxWidth().padding(horizontal = 6.dp),
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        Text(
                            text = "net#$handle",
                            style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                            color = if (focusHandle == handle) MaterialTheme.colorScheme.primary
                                    else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            // Scrollable canvas
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(canvasHeightDp)
                    .horizontalScroll(rememberScrollState()),
            ) {
                Canvas(modifier = Modifier.size(timelineWidthDp, canvasHeightDp)) {
                    // Vertical tick lines at 5 equal intervals
                    for (t in 0..5) {
                        val x = timelineW * t / 5f
                        drawLine(
                            color = Color(0x229E9E9E),
                            start = Offset(x, 0f),
                            end = Offset(x, size.height),
                            strokeWidth = 0.5.dp.toPx(),
                        )
                    }

                    // Overlap lane (row 0): highlight overlap windows
                    overlapIntervals.forEach { ov ->
                        drawRect(
                            color = Color(0x554CAF50),
                            topLeft = Offset(timeToX(ov.startMs), laneH * 0.15f),
                            size = Size((timeToX(ov.endMs) - timeToX(ov.startMs)).coerceAtLeast(2f), laneH * 0.7f),
                        )
                    }

                    // Per-handle lanes (rows 1..n)
                    handles.forEachIndexed { idx, handle ->
                        val laneTop = laneH * (idx + 1)
                        val isFocused = focusHandle == null || focusHandle == handle
                        val barColor = if (isFocused) Color(0xFF2196F3) else Color(0x882196F3)

                        // Baseline
                        drawLine(
                            color = Color(0x339E9E9E),
                            start = Offset(0f, laneTop + laneH / 2),
                            end = Offset(timelineW, laneTop + laneH / 2),
                            strokeWidth = 1.dp.toPx(),
                        )

                        // Availability bars
                        intervals.filter { it.handle == handle }.forEach { iv ->
                            val x1 = timeToX(iv.startMs)
                            val x2 = timeToX(iv.endMs ?: maxTs)
                            val barH = laneH * 0.55f
                            drawRect(
                                // Dimmed if interval is still open (no Lost seen yet)
                                color = barColor.copy(alpha = if (iv.endMs == null) 0.5f else 1f),
                                topLeft = Offset(x1, laneTop + (laneH - barH) / 2),
                                size = Size((x2 - x1).coerceAtLeast(2f), barH),
                            )
                        }

                        // CapabilitiesChanged markers
                        capsMarkers.filter { it.handle == handle }.forEach { m ->
                            val markerColor = when {
                                m.captivePortal -> Color(0xFF9C27B0) // captive portal = purple
                                !m.validated    -> Color(0xFFF44336) // unvalidated = red
                                else            -> Color(0xFF4CAF50) // validated = green
                            }
                            drawCircle(
                                color = markerColor,
                                radius = laneH * 0.18f,
                                center = Offset(timeToX(m.timestampMs), laneTop + laneH / 2),
                            )
                        }
                    }
                }
            }
        }

        // Time scale annotation below the canvas
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = labelWidthDp, end = 8.dp, bottom = 4.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text("0ms", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("${spanMs}ms", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        // Legend
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            LegendDot(Color(0xFF4CAF50), "VAL")
            LegendDot(Color(0xFFF44336), "unv")
            LegendDot(Color(0xFF9C27B0), "captive")
            LegendDot(Color(0x554CAF50), "overlap")
        }

        Spacer(Modifier.height(4.dp))
        Text(
            text = "${handles.size} handle(s)  •  ${events.size} events  •  span ${spanMs}ms",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
        )
    }
}

@Composable
private fun LegendDot(color: Color, label: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
        Canvas(modifier = Modifier.size(8.dp)) {
            drawCircle(color = color, radius = size.minDimension / 2)
        }
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// ---------------------------------------------------------------------------
// Debug action bar
// ---------------------------------------------------------------------------

@Composable
private fun DebugActionsBar(onClear: () -> Unit, onSnapshot: () -> Unit, onDump: () -> Unit) {
    HorizontalDivider()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedButton(onClick = onClear, modifier = Modifier.weight(1f)) { Text("Clear") }
        OutlinedButton(onClick = onSnapshot, modifier = Modifier.weight(1f)) { Text("Snapshot") }
        Button(onClick = onDump, modifier = Modifier.weight(1f)) { Text("Dump") }
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

@Composable
private fun EmptyState(message: String) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = message,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(32.dp),
        )
    }
}

private fun shareText(context: Context, text: String) {
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_SUBJECT, "Connectivity Trace Report")
        putExtra(Intent.EXTRA_TEXT, text)
    }
    context.startActivity(Intent.createChooser(intent, "Export Trace"))
}
