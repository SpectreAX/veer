package com.yamax.veer.core_profile

import android.content.Context
import com.yamax.veer.BuildConfig
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_mihomo.EngineState
import com.yamax.veer.core_mihomo.MihomoEngine
import com.yamax.veer.core_mihomo.ProfileSelectionStore
import com.yamax.veer.core_profile.internal.parser.ImportLogBuilder
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.PipelineStage
import com.yamax.veer.core_profile.internal.parser.ProfileInput
import com.yamax.veer.core_profile.internal.parser.ProfileParser
import com.yamax.veer.core_profile.internal.parser.ValidationError
import com.yamax.veer.core_profile.internal.parser.message
import com.yamax.veer.core_profile.internal.generator.RuntimeConfigGenerator
import com.yamax.veer.core_profile.internal.storage.ProfileStore
import com.yamax.veer.core_profile.internal.storage.ProfileActivationFailure
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

    data class DnsProfileSettings(
        val profileId: ProfileId,
        val profileName: String,
        val policy: DnsOverridePolicy,
        val isActive: Boolean,
    )

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

        val initialIndex = ProfileStore.loadIndexSync(appCtx)
        val initialActive = initialIndex.active
        val activeYaml = initialActive?.let {
            ProfileStore.readGeneratedConfigSync(appCtx, it.profileId)
        }
        if (initialActive != null && activeYaml != null) {
            ConfigManager.setActiveProfile(initialActive.profileId.value, activeYaml)
        }

        scope.launch {
            val index = ProfileStore.loadIndex(appCtx)
            val sanitizedProfiles = index.profiles.map { metadata ->
                val source = metadata.source as? ProfileSource.SubscriptionUrl
                if (source == null) metadata else metadata.copy(
                    displayName = ProfileParser.sanitizeSubscriptionDisplayName(
                        metadata.displayName,
                        source.url,
                    ),
                )
            }
            val sanitizedIndex = if (sanitizedProfiles == index.profiles) {
                index
            } else {
                index.copy(profiles = sanitizedProfiles).also {
                    ProfileStore.saveIndex(appCtx, it)
                }
            }
            _profiles.value = sanitizedIndex.profiles
            _active.value   = sanitizedIndex.active
        }
    }

    // -------------------------------------------------------------------------
    // Import
    // -------------------------------------------------------------------------

    suspend fun import(
        context: Context,
        input: ProfileInput,
        existingId: ProfileId? = null,
        updateActiveRuntime: Boolean = true,
        publishImportState: Boolean = true,
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
        if (publishImportState) {
            _importState.value = ImportState.Running(PipelineStage.FETCH, "Starting import…")
        }

        return when (val result = ProfileParser.parse(
            input,
            id       = existingId ?: ProfileId.generate(),
            cacheDir = appCtx.cacheDir.takeIf { BuildConfig.DEBUG },
        )) {
            is ImportResult.Success -> {
                if (publishImportState) {
                    _importState.value =
                        ImportState.Running(PipelineStage.PERSIST, "Saving profile…")
                }

                val indexBeforeImport = ProfileStore.loadIndex(appCtx)
                val priorMeta = existingId?.let { id ->
                    indexBeforeImport.profiles.find { it.id == id }
                }
                val dnsPolicy = existingId
                    ?.let { indexBeforeImport.dnsOverrides[it.value] }
                    ?: DnsOverridePolicy()
                val effectiveGenerated = RuntimeConfigGenerator.applyDnsOverride(
                    result.generatedYaml,
                    dnsPolicy,
                ).getOrElse { error ->
                    val failure = ImportResult.Failure(
                        errors = listOf(
                            ValidationError.MalformedYaml(
                                "Unable to apply saved DNS settings: ${error.message}",
                            ),
                        ),
                        log = result.log,
                    )
                    if (publishImportState) {
                        _importState.value = ImportState.Failure(
                            failure.errors,
                            failure.errors.first().message(),
                        )
                    }
                    return failure
                }
                val meta = result.profile.metadata.let { refreshed ->
                    val preserved = if (priorMeta != null) {
                        val preservedName = when (val source = refreshed.source) {
                            is ProfileSource.SubscriptionUrl ->
                                ProfileParser.sanitizeSubscriptionDisplayName(
                                    priorMeta.displayName,
                                    source.url,
                                )
                            else -> priorMeta.displayName
                        }
                        refreshed.copy(
                            displayName = preservedName,
                            importedAtMs = priorMeta.importedAtMs,
                            subscriptionUsage =
                                refreshed.subscriptionUsage ?: priorMeta.subscriptionUsage,
                        )
                    }
                    else refreshed
                    preserved.copy(configHashSha256 = effectiveGenerated.sha256Hex)
                }
                val effectiveResult = result.copy(
                    profile = result.profile.copy(metadata = meta),
                    generatedYaml = effectiveGenerated.yaml,
                )
                withContext(Dispatchers.IO) {
                    ProfileStore.saveProfile(
                        context       = appCtx,
                        metadata      = meta,
                        rawYaml       = result.rawYaml,
                        baseGeneratedYaml = result.generatedYaml,
                        effectiveGeneratedYaml = effectiveGenerated.yaml,
                    )

                    val current = ProfileStore.loadIndex(appCtx)
                    val updatedActive = current.active?.let { active ->
                        if (active.profileId == meta.id) {
                            active.copy(generatedConfigHash = meta.configHashSha256)
                        } else active
                    }
                    val updated = current.copy(
                        profiles = current.profiles
                            .filter { it.id != meta.id }
                            .plus(meta),
                        active = updatedActive,
                    )
                    ProfileStore.saveIndex(appCtx, updated)
                    _profiles.value = updated.profiles
                    if (
                        updatedActive?.profileId == meta.id &&
                        updateActiveRuntime &&
                        runtimeIsStopped()
                    ) {
                        ConfigManager.setActiveProfile(meta.id.value, effectiveGenerated.yaml)
                        _active.value = updatedActive
                    }
                }

                VeerLog.profile(
                    "imported: \"${meta.displayName}\"" +
                        " proxies=${meta.proxyCount} groups=${meta.groupCount} rules=${meta.ruleCount}" +
                        " hash=${meta.configHashSha256.take(8)}…"
                )
                if (publishImportState) {
                    _importState.value = ImportState.Success(meta.displayName)
                }
                effectiveResult
            }

            is ImportResult.Failure -> {
                val errSummary = result.errors.joinToString("; ") { it.message() }
                VeerLog.profile("import FAILED: $errSummary", VeerLog.Level.ERROR)
                if (publishImportState) {
                    _importState.value = ImportState.Failure(
                        result.errors,
                        result.errors.firstOrNull()?.message() ?: "Import failed",
                    )
                }
                result
            }
        }
    }

    // -------------------------------------------------------------------------
    // Activate
    // -------------------------------------------------------------------------

    suspend fun activate(context: Context, id: ProfileId): Boolean {
        if (!runtimeIsStopped()) {
            VeerLog.profile("activation rejected while runtime is not stopped", VeerLog.Level.WARN)
            return false
        }
        val appCtx = context.applicationContext
        val yaml   = ProfileStore.readGeneratedConfig(appCtx, id) ?: return false

        val meta = _profiles.value.find { it.id == id } ?: return false

        val active = ActiveProfile(
            profileId           = id,
            activatedAtMs       = System.currentTimeMillis(),
            generatedConfigHash = meta.configHashSha256,
        )

        withContext(Dispatchers.IO) {
            val current = ProfileStore.loadIndex(appCtx)
            ProfileStore.saveIndex(appCtx, current.copy(active = active))
        }
        ConfigManager.setActiveProfile(id.value, yaml)
        _active.value = active
        VeerLog.profile("activated: \"${meta.displayName}\" hash=${active.generatedConfigHash.take(8)}…")
        return true
    }

    /**
     * Snapshots the exact active runtime config after it has reached Running.
     * Safe to call repeatedly; the newest confirmed-good snapshot replaces the
     * previous one atomically.
     */
    suspend fun markActiveAsLastKnownGood(context: Context): ProfileId? {
        val appCtx = context.applicationContext
        val active = _active.value ?: ProfileStore.loadIndex(appCtx).active ?: return null
        val yaml = ProfileStore.readGeneratedConfig(appCtx, active.profileId) ?: return null
        ProfileStore.saveLastKnownGood(appCtx, active, yaml)
        VeerLog.profile(
            "last-known-good saved: profile=${active.profileId.value} " +
                "hash=${active.generatedConfigHash.take(8)}…",
        )
        return active.profileId
    }

    /**
     * Restores both the persisted active-profile pointer and ConfigManager's
     * in-memory YAML from the immutable last-known-good snapshot.
     */
    suspend fun restoreLastKnownGood(context: Context): ProfileId? {
        if (!runtimeIsStopped()) return null
        val appCtx = context.applicationContext
        val snapshot = ProfileStore.loadLastKnownGood(appCtx) ?: return null
        val current = ProfileStore.loadIndex(appCtx)
        if (current.profiles.none { it.id == snapshot.active.profileId }) return null

        ProfileStore.saveIndex(appCtx, current.copy(active = snapshot.active))
        ConfigManager.setActiveProfile(
            snapshot.active.profileId.value,
            snapshot.generatedYaml,
        )
        _active.value = snapshot.active
        VeerLog.profile(
            "last-known-good restored: profile=${snapshot.active.profileId.value} " +
                "hash=${snapshot.active.generatedConfigHash.take(8)}…",
            VeerLog.Level.WARN,
        )
        return snapshot.active.profileId
    }

    suspend fun recordActivationFailure(
        context: Context,
        attemptedProfileId: ProfileId,
        previousProfileId: ProfileId?,
        stage: String,
        message: String,
        rollbackSucceeded: Boolean,
    ) {
        ProfileStore.recordActivationFailure(
            context.applicationContext,
            ProfileActivationFailure(
                attemptedProfileId = attemptedProfileId,
                previousProfileId = previousProfileId,
                stage = stage,
                message = message.take(MAX_FAILURE_MESSAGE_LENGTH),
                occurredAtMs = System.currentTimeMillis(),
                rollbackSucceeded = rollbackSucceeded,
            ),
        )
    }

    // -------------------------------------------------------------------------
    // Deactivate / delete
    // -------------------------------------------------------------------------

    suspend fun deactivate(context: Context) {
        if (!runtimeIsStopped()) return
        val appCtx = context.applicationContext
        ConfigManager.clearActiveProfile()
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
        if (_active.value?.profileId == id && !runtimeIsStopped()) return
        withContext(Dispatchers.IO) {
            val deletingLastKnownGood =
                ProfileStore.loadIndex(appCtx).lastKnownGood?.profileId == id
            ProfileStore.deleteProfile(appCtx, id)
            if (deletingLastKnownGood) {
                ProfileStore.clearLastKnownGood(appCtx)
            }
            ConfigManager.deleteProfileAiRules(appCtx, id.value)
            ProfileSelectionStore.removeProfile(id.value)
            val current = ProfileStore.loadIndex(appCtx)
            val updated = current.copy(
                profiles = current.profiles.filter { it.id != id },
                active   = if (current.active?.profileId == id) null else current.active,
                dnsOverrides = current.dnsOverrides - id.value,
            )
            ProfileStore.saveIndex(appCtx, updated)
            _profiles.value = updated.profiles
            if (current.active?.profileId == id) {
                ConfigManager.clearActiveProfile()
                _active.value = null
            }
        }
    }

    // -------------------------------------------------------------------------
    // Refresh (re-import from original source)
    // -------------------------------------------------------------------------

    suspend fun refresh(context: Context, id: ProfileId): ImportResult {
        val appCtx = context.applicationContext
        if (_active.value?.profileId == id && !runtimeIsStopped()) {
            return ImportResult.Failure(
                errors = listOf(ValidationError.RuntimeMustBeStopped),
                log = ImportLogBuilder().build(),
            )
        }
        val rawYaml = ProfileStore.readRawYaml(appCtx, id)
            ?: return ImportResult.Failure(
                errors = listOf(ValidationError.MalformedYaml("No raw YAML stored for this profile")),
                log    = ImportLogBuilder().build(),
            )
        val meta = _profiles.value.find { it.id == id }
            ?: ProfileStore.loadIndex(appCtx).profiles.find { it.id == id }
        val input = when (val src = meta?.source) {
            is ProfileSource.SubscriptionUrl -> ProfileInput.SubscriptionUrl(src.url)
            else -> ProfileInput.YamlBytes(rawYaml.toByteArray(), meta?.displayName ?: "profile")
        }
        return import(appCtx, input, existingId = id)
    }

    /**
     * Downloads, parses, validates, and atomically persists a subscription
     * without replacing the in-memory config of a currently running VPN.
     * The refreshed config becomes active on the next safe runtime start.
     */
    suspend fun refreshInBackground(context: Context, id: ProfileId): ImportResult {
        val appCtx = context.applicationContext
        val index = ProfileStore.loadIndex(appCtx)
        val meta = index.profiles.find { it.id == id }
            ?: return ImportResult.Failure(
                errors = listOf(ValidationError.MalformedYaml("Profile no longer exists")),
                log = ImportLogBuilder().build(),
            )
        val source = meta.source as? ProfileSource.SubscriptionUrl
            ?: return ImportResult.Failure(
                errors = listOf(ValidationError.MalformedYaml("Profile is not a subscription")),
                log = ImportLogBuilder().build(),
            )
        return import(
            context = appCtx,
            input = ProfileInput.SubscriptionUrl(source.url),
            existingId = id,
            updateActiveRuntime = true,
            publishImportState = false,
        )
    }

    /**
     * Rehydrates the newest validated on-disk profile immediately before a new
     * runtime starts. This is how a background refresh becomes effective on
     * the next reconnect without mutating the currently running core.
     */
    suspend fun installPersistedActiveConfigForStart(context: Context): Boolean {
        val appCtx = context.applicationContext
        val index = ProfileStore.loadIndex(appCtx)
        val active = index.active ?: return false
        val yaml = ProfileStore.readGeneratedConfig(appCtx, active.profileId) ?: return false
        ConfigManager.setActiveProfile(active.profileId.value, yaml)
        _active.value = active
        return true
    }

    // -------------------------------------------------------------------------
    // Per-profile DNS settings
    // -------------------------------------------------------------------------

    suspend fun loadDnsSettings(
        context: Context,
        id: ProfileId? = null,
    ): DnsProfileSettings? {
        val appCtx = context.applicationContext
        val index = ProfileStore.loadIndex(appCtx)
        val targetId = id ?: index.active?.profileId ?: return null
        val metadata = index.profiles.find { it.id == targetId } ?: return null
        return DnsProfileSettings(
            profileId = targetId,
            profileName = metadata.displayName,
            policy = index.dnsOverrides[targetId.value] ?: DnsOverridePolicy(),
            isActive = index.active?.profileId == targetId,
        )
    }

    suspend fun captureDnsSettings(
        context: Context,
        id: ProfileId,
    ): ProfileStore.DnsSettingsSnapshot? =
        ProfileStore.captureDnsSettings(context.applicationContext, id)

    suspend fun applyDnsSettings(
        context: Context,
        id: ProfileId,
        policy: DnsOverridePolicy,
    ): Result<Unit> = runCatching {
        val appCtx = context.applicationContext
        val normalized = policy.normalized()
        val issues = DnsOverrideValidator.validate(normalized)
        require(issues.isEmpty()) {
            issues.joinToString("; ") { it.diagnosticMessage() }
        }
        val index = ProfileStore.loadIndex(appCtx)
        val active = index.active?.profileId == id
        if (active) {
            check(runtimeIsStopped()) {
                "The active profile can only change DNS after the VPN has stopped safely"
            }
        }
        check(index.profiles.any { it.id == id }) { "Profile no longer exists" }
        val baseYaml = ProfileStore.readBaseGeneratedConfig(appCtx, id)
            ?: error("Profile base config is missing")
        ProfileStore.ensureBaseGeneratedConfig(appCtx, id, baseYaml)
        val generated = RuntimeConfigGenerator.applyDnsOverride(baseYaml, normalized).getOrThrow()
        val updated = ProfileStore.commitDnsSettings(
            context = appCtx,
            id = id,
            policy = normalized,
            effectiveGeneratedYaml = generated.yaml,
            effectiveHash = generated.sha256Hex,
        )
        publishIndex(updated)
        if (updated.active?.profileId == id) {
            ConfigManager.setActiveProfile(id.value, generated.yaml)
        }
        VeerLog.profile(
            "DNS settings saved: profile=${id.value} mode=${normalized.mode} " +
                "hash=${generated.sha256Hex.take(8)}…",
        )
    }

    suspend fun restoreDnsSettings(
        context: Context,
        snapshot: ProfileStore.DnsSettingsSnapshot,
    ): ProfileId? {
        if (!runtimeIsStopped()) return null
        val appCtx = context.applicationContext
        val restored = runCatching {
            ProfileStore.restoreDnsSettings(appCtx, snapshot)
        }.getOrNull() ?: return null
        publishIndex(restored)
        if (restored.active?.profileId == snapshot.profileId) {
            ConfigManager.setActiveProfile(snapshot.profileId.value, snapshot.generatedYaml)
        }
        VeerLog.profile(
            "DNS settings rolled back: profile=${snapshot.profileId.value} " +
                "hash=${snapshot.metadataHash.take(8)}…",
            VeerLog.Level.WARN,
        )
        return snapshot.profileId
    }

    private fun publishIndex(index: com.yamax.veer.core_profile.internal.storage.ProfileIndex) {
        _profiles.value = index.profiles
        _active.value = index.active
    }

    private fun runtimeIsStopped(): Boolean = MihomoEngine.state.value is EngineState.Stopped

    private const val MAX_FAILURE_MESSAGE_LENGTH = 500
}
