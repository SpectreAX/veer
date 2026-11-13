package com.yamax.veer.core_mihomo.ipc

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.IBinder

/**
 * Non-exported AIDL endpoint hosted in `:veercore`.
 *
 * CoreStateProvider remains as a compatibility fallback and owns the snapshot
 * implementation. Routing AIDL calls through the provider keeps one validation
 * path for file-sensitive operations such as rule reload while giving the main
 * process a real Binder whose death can be observed.
 */
internal class CoreControlService : Service() {
    private val binder = object : IVeercoreControl.Stub() {
        override fun call(method: String?, extras: Bundle?): Bundle =
            contentResolver.call(
                CoreStateProtocol.URI,
                method.orEmpty(),
                null,
                extras ?: Bundle.EMPTY,
            ) ?: Bundle.EMPTY
    }

    override fun onBind(intent: Intent?): IBinder = binder
}
