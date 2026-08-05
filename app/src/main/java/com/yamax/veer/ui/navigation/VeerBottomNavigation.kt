package com.yamax.veer.ui.navigation

import android.app.Activity
import android.content.Intent
import androidx.activity.ComponentActivity
import androidx.annotation.StringRes
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import com.yamax.veer.MainActivity
import com.yamax.veer.R
import com.yamax.veer.ui.designsystem.preview.VeerPreview
import com.yamax.veer.ui.designsystem.preview.VeerResponsivePreviews
import com.yamax.veer.ui.designsystem.preview.VeerThemePreviews
import com.yamax.veer.ui.nodes.NodesActivity
import com.yamax.veer.ui.profile.ProfileActivity
import com.yamax.veer.ui.rules.RulesActivity
import com.yamax.veer.ui.settings.SettingsActivity

internal enum class VeerTopLevelDestination(
    @param:StringRes val labelRes: Int,
    val icon: ImageVector,
) {
    HOME(R.string.bottom_nav_home, Icons.Default.Home),
    NODES(R.string.bottom_nav_nodes, Icons.AutoMirrored.Filled.List),
    RULES(R.string.bottom_nav_rules, Icons.Default.Star),
    PROFILES(R.string.bottom_nav_profiles, Icons.Default.Edit),
    SETTINGS(R.string.bottom_nav_settings, Icons.Default.Settings),
}

@Composable
internal fun VeerBottomBar(
    selected: VeerTopLevelDestination,
    onSelect: (VeerTopLevelDestination) -> Unit,
    modifier: Modifier = Modifier,
) {
    NavigationBar(
        modifier = modifier.testTag("bottom_navigation"),
    ) {
        VeerTopLevelDestination.entries.forEach { destination ->
            val label = stringResource(destination.labelRes)
            NavigationBarItem(
                selected = selected == destination,
                onClick = { onSelect(destination) },
                icon = {
                    Icon(
                        imageVector = destination.icon,
                        contentDescription = label,
                    )
                },
                label = { Text(label) },
                alwaysShowLabel = true,
                modifier = Modifier.testTag("bottom_nav_${destination.name}"),
            )
        }
    }
}

internal fun ComponentActivity.navigateToTopLevel(destination: VeerTopLevelDestination) {
    if (matches(destination)) return

    val target = when (destination) {
        VeerTopLevelDestination.HOME -> MainActivity::class.java
        VeerTopLevelDestination.NODES -> NodesActivity::class.java
        VeerTopLevelDestination.RULES -> RulesActivity::class.java
        VeerTopLevelDestination.PROFILES -> ProfileActivity::class.java
        VeerTopLevelDestination.SETTINGS -> SettingsActivity::class.java
    }
    startActivity(
        Intent(this, target).addFlags(
            Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP,
        ),
    )
    if (this !is MainActivity) finish()
}

private fun Activity.matches(destination: VeerTopLevelDestination): Boolean = when (destination) {
    VeerTopLevelDestination.HOME -> this is MainActivity
    VeerTopLevelDestination.NODES -> this is NodesActivity
    VeerTopLevelDestination.RULES -> this is RulesActivity
    VeerTopLevelDestination.PROFILES -> this is ProfileActivity
    VeerTopLevelDestination.SETTINGS -> this is SettingsActivity
}

@VeerThemePreviews
@Composable
private fun VeerBottomBarThemePreview() {
    VeerPreview {
        VeerBottomBar(selected = VeerTopLevelDestination.RULES, onSelect = {})
    }
}

@VeerResponsivePreviews
@Composable
private fun VeerBottomBarResponsivePreview() {
    VeerPreview {
        VeerBottomBar(selected = VeerTopLevelDestination.SETTINGS, onSelect = {})
    }
}
