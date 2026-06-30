package com.yamax.veer.core_profile

import android.content.Context
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_profile.internal.parser.ImportLogBuilder
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.PipelineStage
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import com.yamax.veer.core_profile.internal.parser.ProfileParser
import com.yamax.veer.core_profile.internal.parser.ValidationError
import com.yamax.veer.core_profile.internal.parser.message
import com.yamax.veer.core_profile.internal.storage.ProfileStore
import com.yamax.veer.data.ConfigManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Single entry point for all profile operations.
 *
 * Call [init] from [Application.onCreate] before the VPN service starts so the
 * active profile's generated config is installed into [ConfigManager] before
 * [ConfigManager.prepare] runs.
 */
internal object ProfileManager {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val initialized = AtomicBoolean(false)

    private val _profiles    = MutableStateFlow<List<ProfileMetadata>>(emptyList())
    private val _active      = MutableStateFlow<ActiveProfile?>(null)
    private val _importState = MutableStateFlow<ImportState>(ImportState.Idle)

    val profiles:    StateFlow<List<ProfileMetadata>> = _profiles.asStateFlow()
    val active:      StateFlow<ActiveProfile?>        = _active.asStateFlow()
    val importState: StateFlow<ImportState>           = _importState.asStateFlow()

    // -------------------------------------------------------------------------
    // Initialization
    // -------------------------------------------------------------------------

    fun init(context: Context) {
        if (!initialized.compareAndSet(false, true)) return
        val appCtx = context.applicationContext

        val activeYaml = ProfileStore.readActiveConfigYamlSync(appCtx)
        if (activeYaml != null) ConfigManager.activeProfileYaml = activeYaml

        scope.launch {
            val index = ProfileStore.loadIndex(appCtx)
            _profiles.value = index.profiles
            _active.value   = index.active
        }
    }

    // -------------------------------------------------------------------------
    // Import
    // -------------------------------------------------------------------------

    suspend fun import(
        context: Context,
        input: ProfileInput,
        existingId: ProfileId? = null,
    ): ImportResult {
        val appCtx = context.applicationContext

        val inputTag = when (input) {
            is ProfileInput.SubscriptionUrl -> {
                val host = runCatching { java.net.URL(input.url).host }.getOrDefault("unknown")
                "host=$host"
            }
            is ProfileInput.YamlBytes       -> "file=${input.fileName}"
            is ProfileInput.Base64Text      -> "base64(${input.encoded.length} chars)"
        }
        VeerLog.profile("import started: $inputTag")
        _importState.value = ImportState.Running(PipelineStage.FETCH, "Starting import…")

        return when (val result = ProfileParser.parse(
            input,
            id       = existingId ?: ProfileId.generate(),
            cacheDir = appCtx.cacheDir,
        )) {
            is ImportResult.Success -> {
                _importState.value = ImportState.Running(PipelineStage.PERSIST, "Saving profile…")

                val meta = result.profile.metadata
                withContext(Dispatchers.IO) {
                    ProfileStore.saveProfile(
                        context       = appCtx,
                        metadata      = meta,
                        rawYaml       = result.rawYaml,
                        generatedYaml = result.generatedYaml,
                    )

                    val current = ProfileStore.loadIndex(appCtx)
                    val updated = current.copy(
                        profiles = current.profiles
                            .filter { it.id != meta.id }
                            .plus(meta),
                    )
                    ProfileStore.saveIndex(appCtx, updated)
                    _profiles.value = updated.profiles
                }

                VeerLog.profile(
                    "imported: \"${meta.displayName}\"" +
                        " proxies=${meta.proxyCount} groups=${meta.groupCount} rules=${meta.ruleCount}" +
                        " hash=${meta.configHashSha256.take(8)}…"
                )
                _importState.value = ImportState.Success(meta.displayName)
                result
            }

            is ImportResult.Failure -> {
                val errSummary = result.errors.joinToString("; ") { it.message() }
                VeerLog.profile("import FAILED: $errSummary", VeerLog.Level.ERROR)
                _importState.value = ImportState.Failure(
                    result.errors,
                    result.errors.firstOrNull()?.message() ?: "Import failed",
                )
                result
            }
        }
    }

    // -------------------------------------------------------------------------
    // Activate
    // -------------------------------------------------------------------------

    suspend fun activate(context: Context, id: ProfileId): Boolean {
        val appCtx = context.applicationContext
        val yaml   = ProfileStore.readGeneratedConfig(appCtx, id) ?: return false

        val meta = _profiles.value.find { it.id == id } ?: return false

        ConfigManager.activeProfileYaml = yaml

        val active = ActiveProfile(
            profileId           = id,
            activatedAtMs       = System.currentTimeMillis(),
            generatedConfigHash = meta.configHashSha256,
        )

        withContext(Dispatchers.IO) {
            val current = ProfileStore.loadIndex(appCtx)
            ProfileStore.saveIndex(appCtx, current.copy(active = active))
        }
        _active.value = active
        VeerLog.profile("activated: \"${meta.displayName}\" hash=${active.generatedConfigHash.take(8)}…")
        return true
    }

    // -------------------------------------------------------------------------
    // Deactivate / delete
    // -------------------------------------------------------------------------

    suspend fun deactivate(context: Context) {
        val appCtx = context.applicationContext
        ConfigManager.activeProfileYaml = null
        withContext(Dispatchers.IO) {
            val current = ProfileStore.loadIndex(appCtx)
            ProfileStore.saveIndex(appCtx, current.copy(active = null))
        }
        _active.value = null
    }

    fun clearImportState() {
        _importState.value = ImportState.Idle
    }

    suspend fun rename(context: Context, id: ProfileId, newName: String) {
        val appCtx = context.applicationContext
        withContext(Dispatchers.IO) {
            val current = ProfileStore.loadIndex(appCtx)
            val updated = current.copy(
                profiles = current.profiles.map { meta ->
                    if (meta.id == id) meta.copy(displayName = newName) else meta
                }
            )
            ProfileStore.saveIndex(appCtx, updated)
            _profiles.value = updated.profiles
        }
    }

    suspend fun delete(context: Context, id: ProfileId) {
        val appCtx = context.applicationContext
        withContext(Dispatchers.IO) {
            ProfileStore.deleteProfile(appCtx, id)
            val current = ProfileStore.loadIndex(appCtx)
            val updated = current.copy(
                profiles = current.profiles.filter { it.id != id },
                active   = if (current.active?.profileId == id) null else current.active,
            )
            ProfileStore.saveIndex(appCtx, updated)
            _profiles.value = updated.profiles
            if (current.active?.profileId == id) {
                ConfigManager.activeProfileYaml = null
                _active.value = null
            }
        }
    }

    // -------------------------------------------------------------------------
    // Refresh (re-import from original source)
    // -------------------------------------------------------------------------

    suspend fun refresh(context: Context, id: ProfileId): ImportResult {
        val appCtx = context.applicationContext
        val rawYaml = ProfileStore.readRawYaml(appCtx, id)
            ?: return ImportResult.Failure(
                errors = listOf(ValidationError.MalformedYaml("No raw YAML stored for this profile")),
                log    = ImportLogBuilder().build(),
            )
        val meta  = _profiles.value.find { it.id == id }
        val input = when (val src = meta?.source) {
            is ProfileSource.SubscriptionUrl -> ProfileInput.SubscriptionUrl(src.url)
            else -> ProfileInput.YamlBytes(rawYaml.toByteArray(), meta?.displayName ?: "profile")
        }
        return import(appCtx, input, existingId = id)
    }
}
