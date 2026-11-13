package com.yamax.veer.core_mihomo

import com.yamax.veer.core_logging.VeerLog
import veercore.Logger

/**
 * Bridge from the Mihomo Go log stream into [VeerLog].
 *
 * Install before Veercore.start() so the parse/apply phase is captured:
 *   Veercore.setLogger(VeerLogger())
 *
 * Log level is preserved: Go debug/info/warn/error maps to [VeerLog.Level]
 * so that Logcat filtering (`adb logcat -v time Veer:D *:S`) respects severity.
 * All output is routed through [VeerLog.go] and therefore lands in Logcat,
 * the on-disk rolling file, and the ring buffer automatically.
 */
internal class VeerLogger : Logger {
    override fun debug(msg: String) = VeerLog.go(msg, VeerLog.Level.DEBUG)
    override fun info(msg: String)  = VeerLog.go(msg, VeerLog.Level.INFO)
    override fun warn(msg: String)  = VeerLog.go(msg, VeerLog.Level.WARN)
    override fun error(msg: String) = VeerLog.go(msg, VeerLog.Level.ERROR)
}
