package com.yamax.veer.core_profile.internal.storage

import android.content.Context
import com.yamax.veer.core_profile.ActiveProfile
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

/**
 * File-based profile persistence.
 *
 * Layout under [Context.getFilesDir]/profiles/:
 * ```
 * index.json            — serialized [ProfileIndex] (metadata list + active)
 * {id}_raw.yaml         — original user YAML (for refresh)
 * {id}_config.yaml      — generated Mihomo runtime YAML (ready to deploy)
 * ```
 */
internal object ProfileStore {

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
        indexFile(context).writeText(json.encodeToString(index))
    }

    // -------------------------------------------------------------------------
    // Profile files
    // -------------------------------------------------------------------------

    suspend fun saveProfile(
        context: Context,
        metadata: ProfileMetadata,
        rawYaml: String,
        generatedYaml: String,
    ) = withContext(Dispatchers.IO) {
        rawConfigFile(context, metadata.id).writeText(rawYaml)
        generatedConfigFile(context, metadata.id).writeText(generatedYaml)
    }

    suspend fun deleteProfile(context: Context, id: ProfileId) = withContext(Dispatchers.IO) {
        rawConfigFile(context, id).delete()
        generatedConfigFile(context, id).delete()
    }

    suspend fun readGeneratedConfig(context: Context, id: ProfileId): String? =
        withContext(Dispatchers.IO) {
            generatedConfigFile(context, id).takeIf { it.exists() }?.readText()
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
}
