package com.yamax.veer.core_logging

import android.content.Context
import android.util.Log
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Central structured logging for Veer.
 *
 * Every entry carries: timestamp · thread name · category · level · message.
 *
 * Output targets (all writes are fire-and-forget; no exception propagates to callers):
 *   • Logcat — tag "Veer"; use `adb logcat -v time Veer:D *:S` to tail live
 *   • On-disk rolling log — `<logDir>/veer_YYYY-MM-DD.log`, [RETAIN_DAYS]-day retention
 *   • In-memory ring buffer — last [RING_SIZE] entries
 *   • [flow] SharedFlow — collected by the UI log panel
 *
 * Call [init] from [Application.onCreate] before the first [log] call so that
 * on-disk writes are available from the very start of process life.
 */
object VeerLog {

    // -------------------------------------------------------------------------
    // Public types
    // -------------------------------------------------------------------------

    enum class Cat(val key: String) {
        CORE("core"),
        VPN("vpn"),
        CONNECTIVITY("connectivity"),
        PROFILE("profile"),
        PARSER("parser"),
        GO("go"),
        WATCHDOG("watchdog"),
    }

    enum class Level(val letter: Char) {
        DEBUG('D'), INFO('I'), WARN('W'), ERROR('E')
    }

    data class Entry(
        val timestampMs: Long,
        val threadName:  String,
        val cat:         Cat,
        val level:       Level,
        val message:     String,
    )

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    private const val LOGCAT_TAG  = "Veer"
    const val RING_SIZE           = 500
    private const val RETAIN_DAYS = 3L

    // -------------------------------------------------------------------------
    // Output plumbing
    // -------------------------------------------------------------------------

    /** Live log stream for the UI. Same replay / buffer capacity as the old MihomoEngine._logs. */
    private val _flow = MutableSharedFlow<String>(replay = 128, extraBufferCapacity = 512)
    val flow: SharedFlow<String> = _flow.asSharedFlow()

    private val ring     = ArrayDeque<Entry>(RING_SIZE + 1)
    private val ringLock = Any()

    @Volatile private var logDir: File? = null

    // All SimpleDateFormat instances are NOT thread-safe. Guard every format/parse
    // call with fmtLock rather than allocating per-call to avoid GC pressure in
    // high-volume log paths.
    private val fmtLock  = Any()
    private val timeFmt  = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val dateFmt  = SimpleDateFormat("yyyy-MM-dd",   Locale.US)
    private val stampFmt = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    /**
     * Configures the on-disk log directory and prunes files older than
     * [RETAIN_DAYS] days. Safe to call more than once.
     */
    fun init(dir: File) {
        logDir = dir
        runCatching { dir.mkdirs(); pruneOldLogs(dir) }
    }

    // -------------------------------------------------------------------------
    // Category shortcuts
    // -------------------------------------------------------------------------

    fun core(msg: String,         level: Level = Level.DEBUG) = log(Cat.CORE,         msg, level)
    fun vpn(msg: String,          level: Level = Level.DEBUG) = log(Cat.VPN,          msg, level)
    fun connectivity(msg: String, level: Level = Level.DEBUG) = log(Cat.CONNECTIVITY, msg, level)
    fun profile(msg: String,      level: Level = Level.DEBUG) = log(Cat.PROFILE,      msg, level)
    fun parser(msg: String,       level: Level = Level.DEBUG) = log(Cat.PARSER,       msg, level)
    fun go(msg: String,           level: Level = Level.DEBUG) = log(Cat.GO,           msg, level)
    fun watchdog(msg: String,     level: Level = Level.DEBUG) = log(Cat.WATCHDOG,     msg, level)

    // -------------------------------------------------------------------------
    // Core write path
    // -------------------------------------------------------------------------

    fun log(cat: Cat, msg: String, level: Level = Level.DEBUG) {
        val now    = System.currentTimeMillis()
        val thread = Thread.currentThread().name
        val entry  = Entry(now, thread, cat, level, msg)

        // 1. Ring buffer
        synchronized(ringLock) {
            ring.addLast(entry)
            if (ring.size > RING_SIZE) ring.removeFirst()
        }

        val (timeStr, dateStr) = synchronized(fmtLock) {
            val d = Date(now)
            timeFmt.format(d) to dateFmt.format(d)
        }

        // 2. Logcat — tag "Veer" keeps `adb logcat -v time Veer:D *:S` working
        val logcatMsg = "[${cat.key}][$thread] $msg"
        when (level) {
            Level.DEBUG -> Log.d(LOGCAT_TAG, logcatMsg)
            Level.INFO  -> Log.i(LOGCAT_TAG, logcatMsg)
            Level.WARN  -> Log.w(LOGCAT_TAG, logcatMsg)
            Level.ERROR -> Log.e(LOGCAT_TAG, logcatMsg)
        }

        // 3. On-disk rolling log — appendText uses O_APPEND; atomic for lines < PIPE_BUF
        logDir?.let { dir ->
            runCatching {
                File(dir, "veer_$dateStr.log")
                    .appendText("$timeStr ${level.letter} [${cat.key}][$thread] $msg\n")
            }
        }

        // 4. SharedFlow for the UI log panel
        _flow.tryEmit("$timeStr  [${cat.key}]  $msg")
    }

    // -------------------------------------------------------------------------
    // Export
    // -------------------------------------------------------------------------

    /**
     * Writes the current ring buffer snapshot and today's on-disk log file to a
     * single text file under [Context.cacheDir]. Call from a background thread or
     * coroutine — file I/O is synchronous.
     */
    fun exportDebugBundle(context: Context): File {
        val now      = System.currentTimeMillis()
        val bundle   = File(context.cacheDir, "veer_debug_$now.txt")
        val snapshot = synchronized(ringLock) { ring.toList() }

        bundle.bufferedWriter().use { w ->
            val stamp = synchronized(fmtLock) { stampFmt.format(Date(now)) }
            w.write("=== Veer Debug Bundle  $stamp ===\n\n")

            w.write("--- Ring buffer (${snapshot.size}/$RING_SIZE entries) ---\n")
            snapshot.forEach { e ->
                val ts = synchronized(fmtLock) { timeFmt.format(Date(e.timestampMs)) }
                w.write("$ts ${e.level.letter} [${e.cat.key}][${e.threadName}] ${e.message}\n")
            }

            logDir?.let { dir ->
                val today = synchronized(fmtLock) { dateFmt.format(Date(now)) }
                val logFile = File(dir, "veer_$today.log")
                if (logFile.exists()) {
                    w.write("\n--- Log file ${logFile.name} ---\n")
                    logFile.forEachLine { w.write("$it\n") }
                }
            }
        }
        return bundle
    }

    // -------------------------------------------------------------------------
    // Ring access
    // -------------------------------------------------------------------------

    fun ringSnapshot(): List<Entry> = synchronized(ringLock) { ring.toList() }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    private fun pruneOldLogs(dir: File) {
        val cutoff = System.currentTimeMillis() - RETAIN_DAYS * 86_400_000L
        dir.listFiles()
            ?.filter { it.isFile && it.name.startsWith("veer_") && it.name.endsWith(".log") }
            ?.filter { it.lastModified() < cutoff }
            ?.forEach { it.delete() }
    }
}
