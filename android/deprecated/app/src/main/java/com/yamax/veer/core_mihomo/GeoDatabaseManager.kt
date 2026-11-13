package com.yamax.veer.core_mihomo

import android.content.Context
import com.yamax.veer.core_logging.VeerLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Ensures Mihomo geo databases exist on disk before the Go core starts.
 *
 * ## Source priority (per file)
 *
 * 1. **Already on disk and valid** (≥ [MIN_VALID_BYTES]) → use as-is.
 * 2. **APK assets bundle** → copy atomically to homeDir. This is the primary
 *    path; it works fully offline and requires no network access.
 * 3. **Network download** → last resort, only when assets copy also fails.
 *
 * ## Version management
 *
 * `assets/geo_version.txt` carries the build-time version string (e.g. "2026-05-26").
 * After a successful asset copy, the same string is written to `<homeDir>/geo_version.txt`.
 * On subsequent launches: if version matches AND both files are valid → skip copy.
 * When the APK ships a new geo bundle (different version string), the copy runs again,
 * keeping on-disk data in sync with the bundled version.
 *
 * Network downloads do NOT write the version file; they are treated as unversioned.
 * On the next launch, if the asset version ≠ disk version the bundled files are
 * reinstalled (safe: both are valid geo data).
 *
 * ## Network mirrors (fallback only)
 *
 * Ordered CN-accessible first; single-mirror timeout = [PER_MIRROR_CONNECT_TIMEOUT_S].
 */
internal object GeoDatabaseManager {

    const val GEOIP_FILENAME   = "geoip.metadb"
    const val GEOSITE_FILENAME = "geosite.dat"
    private const val VERSION_FILENAME = "geo_version.txt"

    private const val MIN_VALID_BYTES           = 100_000L
    private const val PER_MIRROR_CONNECT_TIMEOUT_S = 8L
    private const val DOWNLOAD_READ_TIMEOUT_S      = 60L

    // CN-accessible mirrors ordered by reliability.
    // Only consulted when the asset bundle is absent or its copy fails.
    private val GEOIP_URLS = listOf(
        "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb",
        "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
        "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
        "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb",
    )
    private val GEOSITE_URLS = listOf(
        "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat",
        "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
        "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
        "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
        "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat",
    )

    private val client = OkHttpClient.Builder()
        .connectTimeout(PER_MIRROR_CONNECT_TIMEOUT_S, TimeUnit.SECONDS)
        .readTimeout(DOWNLOAD_READ_TIMEOUT_S, TimeUnit.SECONDS)
        .followRedirects(true)
        .followSslRedirects(true)
        .build()

    /**
     * Ensures both geo databases are present and valid in [homeDir].
     *
     * - `geoip.metadb` is **required**: returns false if it cannot be obtained from
     *   any source (assets + all network mirrors).
     * - `geosite.dat`  is **best-effort**: failure is logged but does not affect
     *   the return value.
     *
     * Must be called from a coroutine; all I/O runs on [Dispatchers.IO].
     */
    suspend fun ensureGeoDb(context: Context, homeDir: File): Boolean =
        withContext(Dispatchers.IO) {
            syncFromAssets(context, homeDir)
            val geoIpOk = ensureOne(homeDir, GEOIP_FILENAME, GEOIP_URLS, required = true)
            ensureOne(homeDir, GEOSITE_FILENAME, GEOSITE_URLS, required = false)
            geoIpOk
        }

    // -------------------------------------------------------------------------
    // Step 1: asset bundle sync
    // -------------------------------------------------------------------------

    private fun syncFromAssets(context: Context, homeDir: File) {
        val assetVersion = runCatching {
            context.assets.open(VERSION_FILENAME).bufferedReader().readText().trim()
        }.getOrElse {
            VeerLog.vpn("[geo] no bundled geo assets — skipping asset sync")
            return
        }

        val diskVersionFile = File(homeDir, VERSION_FILENAME)
        val diskVersion     = if (diskVersionFile.exists()) diskVersionFile.readText().trim() else ""

        if (diskVersion == assetVersion &&
            isValidFile(File(homeDir, GEOIP_FILENAME)) &&
            isValidFile(File(homeDir, GEOSITE_FILENAME))
        ) {
            VeerLog.vpn("[geo] asset bundle v=$assetVersion already installed — no copy needed")
            return
        }

        VeerLog.vpn(
            "[geo] installing geo bundle v=$assetVersion" +
                " (disk was: ${diskVersion.ifEmpty { "none" }})"
        )

        var allOk = true
        for (name in listOf(GEOIP_FILENAME, GEOSITE_FILENAME)) {
            val dest = File(homeDir, name)
            val ok = runCatching {
                context.assets.open(name).use { input ->
                    val tmp = File(homeDir, "$name.tmp")
                    tmp.outputStream().use { output -> input.copyTo(output) }
                    if (!tmp.renameTo(dest)) {
                        tmp.copyTo(dest, overwrite = true)
                        tmp.delete()
                    }
                }
                VeerLog.vpn("[geo] $name installed from assets (${dest.length()} bytes)")
                true
            }.getOrElse { t ->
                VeerLog.vpn("[geo] $name asset install failed: ${t.message}", VeerLog.Level.WARN)
                false
            }
            if (!ok) allOk = false
        }

        if (allOk) {
            diskVersionFile.writeText(assetVersion)
            VeerLog.vpn("[geo] geo bundle v=$assetVersion installed successfully")
        } else {
            VeerLog.vpn("[geo] geo bundle install incomplete — network fallback will be tried", VeerLog.Level.WARN)
        }
    }

    // -------------------------------------------------------------------------
    // Step 2: per-file ensure (network fallback)
    // -------------------------------------------------------------------------

    private fun ensureOne(
        homeDir:  File,
        name:     String,
        urls:     List<String>,
        required: Boolean,
    ): Boolean {
        val dest = File(homeDir, name)

        if (isValidFile(dest)) {
            VeerLog.vpn("[geo] $name present (${dest.length()} bytes)")
            return true
        }

        if (dest.exists()) {
            VeerLog.vpn(
                "[geo] $name exists but too small (${dest.length()} bytes) — re-downloading",
                VeerLog.Level.WARN,
            )
        } else {
            VeerLog.vpn("[geo] $name missing — attempting network download")
        }

        for (url in urls) {
            val host = runCatching { java.net.URL(url).host }.getOrDefault("unknown")
            VeerLog.vpn("[geo] $name fetching from $host")
            try {
                val bytes = client.newCall(Request.Builder().url(url).build()).execute().use { r ->
                    if (!r.isSuccessful) {
                        VeerLog.vpn("[geo] $name HTTP ${r.code} from $host — try next", VeerLog.Level.WARN)
                        return@use null
                    }
                    r.body?.bytes()
                }

                if (bytes == null || bytes.size < MIN_VALID_BYTES) {
                    VeerLog.vpn(
                        "[geo] $name received ${bytes?.size ?: 0} bytes from $host (too small) — try next",
                        VeerLog.Level.WARN,
                    )
                    continue
                }

                val tmp = File(homeDir, "$name.tmp")
                tmp.writeBytes(bytes)
                if (!tmp.renameTo(dest)) {
                    tmp.copyTo(dest, overwrite = true)
                    tmp.delete()
                }
                VeerLog.vpn("[geo] $name saved ${dest.length()} bytes from $host")
                return true
            } catch (e: Exception) {
                VeerLog.vpn("[geo] $name error from $host: ${e.message}", VeerLog.Level.WARN)
            }
        }

        val level = if (required) VeerLog.Level.ERROR else VeerLog.Level.WARN
        VeerLog.vpn(
            "[geo] $name all sources failed — " +
                if (required) "GEOIP rules will fail" else "GEOSITE rules may fail",
            level,
        )
        return false
    }

    private fun isValidFile(f: File) = f.exists() && f.length() >= MIN_VALID_BYTES
}
