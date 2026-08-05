package com.yamax.veer.ui.profile

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.ui.dns.DnsSettingsActivity
import com.yamax.veer.ui.theme.VeerTheme
import com.yamax.veer.ui.navigation.VeerBottomBar
import com.yamax.veer.ui.navigation.VeerTopLevelBackHandler
import com.yamax.veer.ui.navigation.VeerTopLevelDestination
import com.yamax.veer.ui.navigation.navigateToTopLevel

class ProfileActivity : ComponentActivity() {

    private sealed class ProfileRoute {
        data object List : ProfileRoute()
        data class Detail(val profileId: ProfileId) : ProfileRoute()
    }

    private var currentRoute by mutableStateOf<ProfileRoute>(ProfileRoute.List)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            VeerTheme {
                VeerTopLevelBackHandler(enabled = currentRoute is ProfileRoute.List)
                BackHandler(enabled = currentRoute is ProfileRoute.Detail) {
                    currentRoute = ProfileRoute.List
                }
                when (val route = currentRoute) {
                    is ProfileRoute.List   -> ProfileListScreen(
                        onBack = { navigateToTopLevel(VeerTopLevelDestination.HOME) },
                        onProfileDetail = { id -> currentRoute = ProfileRoute.Detail(id) },
                        onProfileDns = { id ->
                            startActivity(DnsSettingsActivity.intent(this, id))
                        },
                        showBackNavigation = false,
                        bottomBar = {
                            VeerBottomBar(
                                selected = VeerTopLevelDestination.PROFILES,
                                onSelect = ::navigateToTopLevel,
                            )
                        },
                    )
                    is ProfileRoute.Detail -> ProfileDetailScreen(
                        profileId = route.profileId,
                        onBack    = { currentRoute = ProfileRoute.List },
                    )
                }
            }
        }
    }
}
