package com.yamax.veer.ui.designsystem.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

/** The shared 4 dp spacing grid used by all Veer screens and components. */
object VeerSpacing {
    val none = 0.dp
    val xxs = 2.dp
    val xs = 4.dp
    val sm = 8.dp
    val md = 12.dp
    val lg = 16.dp
    val xl = 24.dp
    val xxl = 32.dp
    val xxxl = 48.dp
}

object VeerShapes {
    val small = RoundedCornerShape(8.dp)
    val medium = RoundedCornerShape(12.dp)
    val large = RoundedCornerShape(20.dp)
    val extraLarge = RoundedCornerShape(28.dp)
    val pill = RoundedCornerShape(percent = 50)
}

object VeerElevation {
    val none = 0.dp
    val low = 1.dp
    val medium = 3.dp
    val high = 6.dp
}

object VeerMotion {
    const val quick = 150
    const val standard = 250
    const val emphasized = 300
}

object VeerDimensions {
    val touchTarget = 48.dp
    val iconSmall = 16.dp
    val iconMedium = 24.dp
    val iconLarge = 32.dp
    val appIcon = 40.dp
    val stateIcon = 48.dp
    val contentMaxWidth = 720.dp
    val formMaxWidth = 560.dp
    val diagnosticPanelHeight = 320.dp
    val speedChartHeight = 120.dp
    val dialogListMaxHeight = 420.dp
    val compactContentBreakpoint = 320.dp
    val compactContentHeight = 640.dp
    val divider = 1.dp
    val progressStroke = 2.dp
    val chartPointRadius = 2.dp
}

object VeerAlpha {
    const val disabled = 0.38f
    const val disabledContainer = 0.12f
    const val subtle = 0.68f
    const val outline = 0.50f
}
