package com.yamax.veer.core_profile.internal.storage

import android.content.Context
import com.yamax.veer.core_profile.ActiveProfile
import com.yamax.veer.core_profile.DnsOverrideMode
import com.yamax.veer.core_profile.DnsOverridePolicy
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

/**
 * File-based profile persistence.
 *
 * Layout under [Context.getFilesDir]/profiles/:
 * ```
 * index.json            — serialized [ProfileIndex] (metadata list + active)
 * {id}_raw.yaml         — original user YAML (for refresh)
 * {id}_base_config.yaml — generated YAML before the per-profile DNS overlay
 * {id}_config.yaml      — effective Mihomo runtime YAML (ready to deploy)
 * ```
 */
internal object ProfileStore {

    private val indexMutex = Mutex()

    data class LastKnownGoodSnapshot(
        val active: ActiveProfile,
        val generatedYaml: String,
    )

    data class DnsSettingsSnapshot(
        val profileId: ProfileId,
        val policy: DnsOverridePolicy?,
        val generatedYaml: String,
        val metadataHash: String,
        val activeHash: String?,
    )

    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    // -------------------------------------------------------------------------
    // Index
    // -------------------------------------------------------------------------

    suspend fun loadIndex(context: Context): ProfileIndex = withContext(Dispatchers.IO) {
        val file = indexFile(context)
        if (!file.exists()) return@withContext ProfileIndex()
        runCatching { json.decodeFromString<ProfileIndex>(file.readText()) }
            .getOrDefault(ProfileIndex())
    }

    fun loadIndexSync(context: Context): ProfileIndex {
        val file = indexFile(context)
        if (!file.exists()) return ProfileIndex()
        return runCatching { json.decodeFromString<ProfileIndex>(file.readText()) }
            .getOrDefault(ProfileIndex())
    }

    suspend fun saveIndex(context: Context, index: ProfileIndex) = withContext(Dispatchers.IO) {
        indexMutex.withLock {
            atomicWrite(indexFile(context), json.encodeToString(index))
        }
    }

    /**
     * Stores the exact generated YAML that reached Running, not only a profile
     * ID. A later failed refresh of the same profile therefore cannot overwrite
     * the rollback payload.
     */
    suspend fun saveLastKnownGood(
        context: Context,
        active: ActiveProfile,
        generatedYaml: String,
    ) = withContext(Dispatchers.IO) {
        indexMutex.withLock {
            atomicWrite(lastKnownGoodConfigFile(context), generatedYaml)
            val current = loadIndexSync(context)
            atomicWrite(
                indexFile(context),
                json.encodeToString(
                    current.copy(
                        lastKnownGood = active,
                        lastActivationFailure = null,
                    ),
                ),
            )
        }
    }

    suspend fun loadLastKnownGood(context: Context): LastKnownGoodSnapshot? =
        withContext(Dispatchers.IO) {
            val active = loadIndexSync(context).lastKnownGood
                ?: return@withContext null
            val config = lastKnownGoodConfigFile(context)
            if (!config.exists()) return@withContext null
            LastKnownGoodSnapshot(active, config.readText())
        }

    suspend fun recordActivationFailure(
        context: Context,
        failure: ProfileActivationFailure,
    ) = withContext(Dispatchers.IO) {
        indexMutex.withLock {
            val current = loadIndexSync(context)
            atomicWrite(
                indexFile(context),
                json.encodeToString(current.copy(lastActivationFailure = failure)),
            )
        }
    }

    suspend fun clearLastKnownGood(context: Context) = withContext(Dispatchers.IO) {
        indexMutex.withLock {
            lastKnownGoodConfigFile(context).delete()
            val current = loadIndexSync(context)
            atomicWrite(indexFile(context), json.encodeToString(current.copy(lastKnownGood = null)))
        }
    }

    // -------------------------------------------------------------------------
    // Profile files
    // -------------------------------------------------------------------------

    suspend fun saveProfile(
        context: Context,
        metadata: ProfileMetadata,
        rawYaml: String,
        baseGeneratedYaml: String,
        effectiveGeneratedYaml: String,
    ) = withContext(Dispatchers.IO) {
        atomicWrite(rawConfigFile(context, metadata.id), rawYaml)
        atomicWrite(baseGeneratedConfigFile(context, metadata.id), baseGeneratedYaml)
        atomicWrite(generatedConfigFile(context, metadata.id), effectiveGeneratedYaml)
    }

    suspend fun deleteProfile(context: Context, id: ProfileId) = withContext(Dispatchers.IO) {
        rawConfigFile(context, id).delete()
        baseGeneratedConfigFile(context, id).delete()
        generatedConfigFile(context, id).delete()
    }

    suspend fun readGeneratedConfig(context: Context, id: ProfileId): String? =
        withContext(Dispatchers.IO) {
            readGeneratedConfigSync(context, id)
        }

    fun readGeneratedConfigSync(context: Context, id: ProfileId): String? =
        generatedConfigFile(context, id).takeIf { it.exists() }?.readText()

    suspend fun readBaseGeneratedConfig(context: Context, id: ProfileId): String? =
        withContext(Dispatchers.IO) {
            readBaseGeneratedConfigSync(context, id)
        }

    /**
     * Legacy profiles have no base file. Their effective config predates DNS
     * overlays, so it is an exact safe migration source.
     */
    fun readBaseGeneratedConfigSync(context: Context, id: ProfileId): String? =
        baseGeneratedConfigFile(context, id).takeIf { it.exists() }?.readText()
            ?: readGeneratedConfigSync(context, id)

    suspend fun ensureBaseGeneratedConfig(
        context: Context,
        id: ProfileId,
        generatedYaml: String,
    ) = withContext(Dispatchers.IO) {
        val target = baseGeneratedConfigFile(context, id)
        if (!target.exists()) atomicWrite(target, generatedYaml)
    }

    suspend fun readRawYaml(context: Context, id: ProfileId): String? =
        withContext(Dispatchers.IO) {
            rawConfigFile(context, id).takeIf { it.exists() }?.readText()
        }

    /**
     * Synchronous read of the active profile's generated config. Called from
     * [ProfileManager.init] on the main thread during app startup before the
     * service reads [ConfigManager.baseConfigFile].
     */
    fun readActiveConfigYamlSync(context: Context): String? {
        val active = loadIndexSync(context).active ?: return null
        val file = generatedConfigFile(context, active.profileId)
        return if (file.exists()) file.readText() else null
    }

    suspend fun captureDnsSettings(
        context: Context,
        id: ProfileId,
    ): DnsSettingsSnapshot? = withContext(Dispatchers.IO) {
        indexMutex.withLock {
            val current = loadIndexSync(context)
            val metadata = current.profiles.find { it.id == id }
                ?: return@withLock null
            val generated = readGeneratedConfigSync(context, id)
                ?: return@withLock null
            DnsSettingsSnapshot(
                profileId = id,
                policy = current.dnsOverrides[id.value],
                generatedYaml = generated,
                metadataHash = metadata.configHashSha256,
                activeHash = current.active
                    ?.takeIf { it.profileId == id }
                    ?.generatedConfigHash,
            )
        }
    }

    /**
     * Commits the policy, effective YAML and all published hashes as one
     * logical operation. If the index write fails, the previous effective YAML
     * is restored before the error escapes.
     */
    suspend fun commitDnsSettings(
        context: Context,
        id: ProfileId,
        policy: DnsOverridePolicy,
        effectiveGeneratedYaml: String,
        effectiveHash: String,
    ): ProfileIndex = withContext(Dispatchers.IO) {
        indexMutex.withLock {
            val current = loadIndexSync(context)
            require(current.profiles.any { it.id == id }) { "Profile no longer exists" }
            val oldGenerated = readGeneratedConfigSync(context, id)
            val normalized = policy.normalized()
            val overrides = current.dnsOverrides.toMutableMap().apply {
                if (normalized.mode == DnsOverrideMode.INHERIT) {
                    remove(id.value)
                } else {
                    put(id.value, normalized)
                }
            }
            val updated = current.copy(
                profiles = current.profiles.map { metadata ->
                    if (metadata.id == id) {
                        metadata.copy(configHashSha256 = effectiveHash)
                    } else {
                        metadata
                    }
                },
                active = current.active?.let { active ->
                    if (active.profileId == id) {
                        active.copy(generatedConfigHash = effectiveHash)
                    } else {
                        active
                    }
                },
                dnsOverrides = overrides,
            )
            try {
                atomicWrite(generatedConfigFile(context, id), effectiveGeneratedYaml)
                atomicWrite(indexFile(context), json.encodeToString(updated))
            } catch (error: Throwable) {
                if (oldGenerated != null) {
                    runCatching {
                        atomicWrite(generatedConfigFile(context, id), oldGenerated)
                    }
                }
                throw error
            }
            updated
        }
    }

    suspend fun restoreDnsSettings(
        context: Context,
        snapshot: DnsSettingsSnapshot,
    ): ProfileIndex = withContext(Dispatchers.IO) {
        indexMutex.withLock {
            val current = loadIndexSync(context)
            require(current.profiles.any { it.id == snapshot.profileId }) {
                "Profile no longer exists"
            }
            val overrides = current.dnsOverrides.toMutableMap().apply {
                if (snapshot.policy == null) {
                    remove(snapshot.profileId.value)
                } else {
                    put(snapshot.profileId.value, snapshot.policy)
                }
            }
            val restored = current.copy(
                profiles = current.profiles.map { metadata ->
                    if (metadata.id == snapshot.profileId) {
                        metadata.copy(configHashSha256 = snapshot.metadataHash)
                    } else {
                        metadata
                    }
                },
                active = current.active?.let { active ->
                    if (active.profileId == snapshot.profileId && snapshot.activeHash != null) {
                        active.copy(generatedConfigHash = snapshot.activeHash)
                    } else {
                        active
                    }
                },
                dnsOverrides = overrides,
            )
            atomicWrite(
                generatedConfigFile(context, snapshot.profileId),
                snapshot.generatedYaml,
            )
            atomicWrite(indexFile(context), json.encodeToString(restored))
            restored
        }
    }

    // -------------------------------------------------------------------------
    // Path helpers
    // -------------------------------------------------------------------------

    private fun profilesDir(context: Context): File =
        File(context.filesDir, "profiles").apply { mkdirs() }

    private fun indexFile(context: Context): File =
        File(profilesDir(context), "index.json")

    fun rawConfigFile(context: Context, id: ProfileId): File =
        File(profilesDir(context), "${id.value}_raw.yaml")

    fun generatedConfigFile(context: Context, id: ProfileId): File =
        File(profilesDir(context), "${id.value}_config.yaml")

    fun baseGeneratedConfigFile(context: Context, id: ProfileId): File =
        File(profilesDir(context), "${id.value}_base_config.yaml")

    private fun lastKnownGoodConfigFile(context: Context): File =
        File(profilesDir(context), "last_known_good_config.yaml")

    private fun atomicWrite(target: File, content: String) {
        val temporary = File(target.parentFile, ".${target.name}.${UUID.randomUUID()}.tmp")
        try {
            temporary.outputStream().bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write(content)
            }
            runCatching {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                    StandardCopyOption.ATOMIC_MOVE,
                )
            }.getOrElse {
                Files.move(
                    temporary.toPath(),
                    target.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } finally {
            temporary.delete()
        }
    }
}
