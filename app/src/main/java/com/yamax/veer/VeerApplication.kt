package com.yamax.veer

import android.app.Application
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
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
        ThemePreference.initialize(this)
        val coreProcess = ProcessRole.isCoreProcess()
        VeerLog.init(File(filesDir, if (coreProcess) "logs/core" else "logs"))
        ProfileManager.init(this)
        AppStateRepository.init()
        if (coreProcess) {
            CoreStatePublisher.init(this)
        } else {
            SubscriptionRefreshHistory.init(this)
            SubscriptionRefreshScheduler.schedule(this)
            CoreStateClient.init(this)
        }
    }
}
