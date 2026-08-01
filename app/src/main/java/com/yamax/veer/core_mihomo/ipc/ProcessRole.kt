package com.yamax.veer.core_mihomo.ipc

import android.app.Application

internal object ProcessRole {
    private const val CORE_SUFFIX = ":veercore"

    fun isCoreProcess(): Boolean =
        isCoreProcessName(runCatching { Application.getProcessName() }.getOrNull())

    internal fun isCoreProcessName(processName: String?): Boolean =
        processName?.endsWith(CORE_SUFFIX) == true
}
