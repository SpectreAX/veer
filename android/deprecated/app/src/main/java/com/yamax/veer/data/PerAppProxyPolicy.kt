package com.yamax.veer.data

import android.content.Context
import com.yamax.veer.core_logging.VeerLog
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * Controls which Android applications are attached to Veer's VPN interface.
 *
 * The policy is device-wide rather than profile-scoped: changing a proxy
 * subscription must not silently change which apps are allowed to use the VPN.
 */
@Serializable
internal enum class PerAppProxyMode {
    /** All applications use the VPN, except Veer itself. */
    ALL_APPS,

    /** Only [PerAppProxyPolicy.packageNames] use the VPN. */
    ONLY_SELECTED,

    /** All applications except [PerAppProxyPolicy.packageNames] use the VPN. */
    BYPASS_SELECTED,
}

@Serializable
internal data class PerAppProxyPolicy(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val mode: PerAppProxyMode = PerAppProxyMode.ALL_APPS,
    val packageNames: Set<String> = emptySet(),
) {
    fun normalized(): PerAppProxyPolicy = copy(
        schemaVersion = CURRENT_SCHEMA_VERSION,
        packageNames = packageNames
            .asSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .take(MAX_PACKAGES)
            .toSortedSet(),
    )

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
        const val MAX_PACKAGES = 1_000
    }
}

/**
 * Atomic, cross-process persistence for [PerAppProxyPolicy].
 *
 * SharedPreferences does not provide reliable live multi-process coherence.
 * A replace-on-rename JSON file gives the UI process one writer and the
 * `:veercore` process a consistent snapshot at TUN establishment time.
 */
internal object PerAppProxyPolicyStore {
    private const val SETTINGS_DIRECTORY = "settings"
    private const val FILE_NAME = "per_app_proxy.json"

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    fun read(context: Context): PerAppProxyPolicy = read(policyFile(context))

    fun write(context: Context, policy: PerAppProxyPolicy) {
        write(policyFile(context), policy)
    }

    internal fun read(file: File): PerAppProxyPolicy {
        if (!file.isFile) return PerAppProxyPolicy()
        return runCatching {
            json.decodeFromString<PerAppProxyPolicy>(file.readText()).normalized()
        }.onFailure {
            VeerLog.core(
                "[per-app] invalid policy ignored: ${it.message}",
                VeerLog.Level.WARN,
            )
        }.getOrDefault(PerAppProxyPolicy())
    }

    internal fun write(file: File, policy: PerAppProxyPolicy) {
        file.parentFile?.mkdirs()
        val temporary = File(
            file.parentFile,
            ".${file.name}.${UUID.randomUUID()}.tmp",
        )
        try {
            temporary.outputStream().bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write(json.encodeToString(policy.normalized()))
            }
            runCatching {
                Files.move(
                    temporary.toPath(),
                    file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            }.recoverCatching {
                Files.move(
                    temporary.toPath(),
                    file.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }.getOrThrow()
        } finally {
            temporary.delete()
        }
    }

    private fun policyFile(context: Context): File =
        File(File(context.filesDir, SETTINGS_DIRECTORY), FILE_NAME)
}
