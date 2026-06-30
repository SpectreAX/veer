package com.yamax.veer

import android.app.Application
import com.yamax.veer.app_state.AppStateRepository
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_profile.ProfileManager
import java.io.File

class VeerApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        VeerLog.init(File(filesDir, "logs"))
        ProfileManager.init(this)
        AppStateRepository.init()
    }
}
