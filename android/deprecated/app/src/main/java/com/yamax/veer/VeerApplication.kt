package com.yamax.veer

import android.app.Application
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.ControllerSecretStore
import com.yamax.veer.core_mihomo.ProfileSelectionStore
import com.yamax.veer.core_mihomo.ipc.CoreStateClient
import com.yamax.veer.core_mihomo.ipc.CoreStatePublisher
import com.yamax.veer.core_mihomo.ipc.ProcessRole
import com.yamax.veer.core_profile.ProfileManager
import com.yamax.veer.core_profile.SubscriptionRefreshHistory
import com.yamax.veer.core_profile.SubscriptionRefreshScheduler
import com.yamax.veer.ui.theme.ThemePreference
import java.io.File

class VeerApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        ControllerSecretStore.initialize(this)
        ProfileSelectionStore.initialize(this)
        val coreProcess = ProcessRole.isCoreProcess()
        VeerLog.init(File(filesDir, if (coreProcess) "logs/core" else "logs"))
        AppStateRepository.init()
        if (coreProcess) {
            // Keep remote-process Application startup minimal. ContentProvider
            // publication is subject to Android's process-start timeout; reading
            // a large active profile here can make the system kill both the core
            // and its waiting client. Profile initialization runs from bootCore
            // after foreground-service promotion, on Dispatchers.IO.
            CoreStatePublisher.init(this)
        } else {
            ThemePreference.initialize(this)
            ProfileManager.init(this)
            SubscriptionRefreshHistory.init(this)
            SubscriptionRefreshScheduler.schedule(this)
            CoreStateClient.init(this)
        }
    }
}
