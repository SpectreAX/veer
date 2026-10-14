package com.yamax.veer.core_mihomo

import android.content.Context
import com.yamax.veer.data.ConfigManager
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID

/** Persists selector choices by profile, separately from Mihomo's global cache. */
internal object ProfileSelectionStore {
    private const val DEFAULT_SCOPE = "__default__"
    @Volatile private var directory: File? = null

    fun initialize(context: Context) {
        directory = File(context.noBackupFilesDir, "proxy-selections")
    }

    fun recordActive(group: String, selected: String) {
        val profileId = ConfigManager.activeProfileId() ?: DEFAULT_SCOPE
        val home = directory ?: return
        update(home, profileId) { it[group] = selected }
    }

    fun removeProfile(profileId: String) {
        directory?.let { home -> locked(home, profileId) { file(home, profileId).delete() } }
    }

    suspend fun restoreActive(repository: MihomoRepository) {
        val profileId = ConfigManager.activeProfileId() ?: DEFAULT_SCOPE
        val home = directory ?: return
        val saved = read(home, profileId)
        if (saved.isEmpty()) return
        val snapshot = repository.routingSnapshot()
        if (snapshot.proxies.isEmpty()) return // A failed Controller read is not a deleted group.
        val valid = validSelections(saved, snapshot)
        if (valid != saved) update(home, profileId) { choices ->
            choices.keys.retainAll(valid.keys)
        }
        valid.forEach { (group, selected) ->
            if (snapshot.proxies[group]?.now != selected) repository.selectProxy(group, selected)
        }
    }

    internal fun validSelections(
        saved: Map<String, String>,
        snapshot: MihomoRepository.RoutingSnapshot,
    ): Map<String, String> = saved.filter { (group, selected) ->
        snapshot.proxies[group]?.let { it.type == "Selector" && selected in it.members } == true
    }

    internal fun read(home: File, profileId: String): Map<String, String> = locked(home, profileId) {
        readUnlocked(file(home, profileId))
    }

    internal fun record(home: File, profileId: String, group: String, selected: String) {
        update(home, profileId) { it[group] = selected }
    }

    private fun update(home: File, profileId: String, change: (MutableMap<String, String>) -> Unit) {
        locked(home, profileId) {
            val target = file(home, profileId)
            val choices = readUnlocked(target).toMutableMap()
            change(choices)
            val temp = File(home, "${target.name}.${UUID.randomUUID()}.tmp")
            try {
                temp.writeText(Json.encodeToString(choices))
                Files.move(temp.toPath(), target.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } finally {
                temp.delete()
            }
        }
    }

    private fun readUnlocked(target: File): Map<String, String> =
        if (!target.exists()) emptyMap()
        else runCatching { Json.decodeFromString<Map<String, String>>(target.readText()) }
            .getOrDefault(emptyMap())

    private fun <T> locked(home: File, profileId: String, action: () -> T): T = synchronized(this) {
        check(home.isDirectory || home.mkdirs()) { "Cannot create profile selection directory" }
        java.io.RandomAccessFile(File(home, "${file(home, profileId).name}.lock"), "rw").use { handle ->
            handle.channel.lock().use { action() }
        }
    }

    private fun file(home: File, profileId: String): File {
        val hash = MessageDigest.getInstance("SHA-256")
            .digest(profileId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return File(home, "$hash.json")
    }
}
