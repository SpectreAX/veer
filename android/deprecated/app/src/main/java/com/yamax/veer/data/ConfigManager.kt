package com.yamax.veer.data

import android.content.Context
import com.yamax.veer.core_mihomo.ControllerSecretStore
import com.yamax.veer.core_profile.SubscriptionMetadata
import org.yaml.snakeyaml.DumperOptions
import org.yaml.snakeyaml.LoaderOptions
import org.yaml.snakeyaml.Yaml
import org.yaml.snakeyaml.constructor.SafeConstructor
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID

internal enum class AiRuleHealth {
    ACTIVE,
    DISABLED,
    MISSING_POLICY,
    NOT_LOADED,
}

internal data class ManagedAiRule(
    val id: String,
    val raw: String,
    val matchType: String,
    val target: String,
    val policy: String,
    val enabled: Boolean,
    val policyAvailable: Boolean,
    val loadedInMaterializedConfig: Boolean,
) {
    val health: AiRuleHealth
        get() = when {
            !enabled -> AiRuleHealth.DISABLED
            !policyAvailable -> AiRuleHealth.MISSING_POLICY
            !loadedInMaterializedConfig -> AiRuleHealth.NOT_LOADED
            else -> AiRuleHealth.ACTIVE
        }
}

internal data class AiRulesSnapshot(
    val profileId: String,
    val rules: List<ManagedAiRule>,
    val availablePolicies: List<String>,
)

internal data class AiRuleStore(
    val enabled: List<String> = emptyList(),
    val disabled: List<String> = emptyList(),
)

internal data class ParsedAiRule(
    val id: String,
    val raw: String,
    val matchType: String,
    val target: String,
    val policy: String,
    val matcher: String,
    val policyIndex: Int,
)

/**
 * Copies the bundled Mihomo assets into the app's internal storage so the Go
 * core (which only accepts filesystem paths) can read them.
 *
 * The home directory layout after [prepare] is:
 *
 * ```
 * <filesDir>/mihomo/
 *   base.yaml             # canonical config with active-profile AI rules merged in
 *   ai_override.yaml      # legacy global AI rules; migration source only
 *   ai_rules/{scope}.yaml # persistent AI rules isolated by profile ID
 * ```
 */
object ConfigManager {

    private const val HOME_DIR = "mihomo"
    private const val AI_RULES_DIR = "ai_rules"
    private const val LEGACY_MIGRATION_MARKER = ".legacy_migrated"
    private const val DEFAULT_RULE_SCOPE = "__default__"
    const val BASE_CONFIG = "base.yaml"
    const val AI_OVERRIDE = "ai_override.yaml"

    private data class ActiveProfileConfig(val profileId: String, val yaml: String)

    /**
     * Profile ID and YAML are published as one volatile value so the VPN cannot
     * combine one profile's config with another profile's AI-rule scope.
     */
    @Volatile private var activeProfile: ActiveProfileConfig? = null

    fun setActiveProfile(profileId: String, yaml: String) {
        require(profileId.isNotBlank()) { "profileId must not be blank" }
        activeProfile = ActiveProfileConfig(profileId, yaml)
    }

    fun clearActiveProfile() {
        activeProfile = null
    }

    /** Profile scope used by AI history and other profile-bound runtime state. */
    internal fun activeProfileId(): String? = activeProfile?.profileId

    /**
     * Materialises the Mihomo home directory and returns it.
     *
     * `base.yaml` is overwritten on every call: either with the active profile
     * when a profile is active, or with the bundled asset otherwise.
     * Legacy `ai_override.yaml` is seeded only to support one-time migration.
     */
    @Throws(IOException::class)
    @Synchronized
    fun prepare(context: Context): File {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        ensureLegacyRulesMigrated(home)
        materializeBaseConfig(context, home)
        return home
    }

    /** Rebuilds base.yaml after an AI rule change and returns the file to hot-reload. */
    @Synchronized
    fun materializeBaseConfig(context: Context): File {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        ensureLegacyRulesMigrated(home)
        return materializeBaseConfig(context, home)
    }

    /** Adds [rule] once. Returns false when an identical rule already exists. */
    @Synchronized
    fun addAiRule(context: Context, rule: String): Boolean {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        ensureLegacyRulesMigrated(home)
        val file = scopedAiRulesFile(home, activeRuleScope())
        file.parentFile?.mkdirs()
        val store = readAiRuleStore(file)
        val (rules, changed) = upsertAiRule(store.enabled, rule)
        val matcher = parseAiRule(rule)?.matcher
        val disabled = store.disabled.filterNot { parseAiRule(it)?.matcher == matcher }
        if (changed || disabled != store.disabled) {
            atomicWrite(file, dumpAiRuleStore(AiRuleStore(rules, disabled)))
        }
        return changed
    }

    /** Reads the exact active-profile rule store for transactional callers. */
    @Synchronized
    internal fun activeAiRuleStore(context: Context): AiRuleStore {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        ensureLegacyRulesMigrated(home)
        return readAiRuleStore(scopedAiRulesFile(home, activeRuleScope()))
    }

    /** Atomically replaces the active-profile store, including disabled rules. */
    @Synchronized
    internal fun replaceActiveAiRuleStore(context: Context, store: AiRuleStore) {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        ensureLegacyRulesMigrated(home)
        val file = scopedAiRulesFile(home, activeRuleScope())
        file.parentFile?.mkdirs()
        atomicWrite(file, dumpAiRuleStore(store.normalized()))
    }

    /**
     * Pure batch upsert used by an AI-plan transaction. The returned booleans
     * correspond to [rules] and indicate whether that operation changed the
     * store. No file is written until the caller commits the returned store.
     */
    internal fun upsertAiRules(
        store: AiRuleStore,
        rules: List<String>,
    ): Pair<AiRuleStore, List<Boolean>> {
        var current = store.normalized()
        val changes = rules.map { rule ->
            val (enabled, changed) = upsertAiRule(current.enabled, rule)
            val matcher = parseAiRule(rule)?.matcher
            val disabled = current.disabled.filterNot { parseAiRule(it)?.matcher == matcher }
            val next = AiRuleStore(enabled, disabled).normalized()
            val actuallyChanged = next != current
            current = next
            changed || actuallyChanged
        }
        return current to changes
    }

    internal fun upsertAiRule(existing: List<String>, rule: String): Pair<List<String>, Boolean> {
        if (rule in existing) return existing.distinct() to false
        val matcher = parseAiRule(rule)?.matcher ?: rule.substringBeforeLast(',')
        val updated = existing.filterNot {
            (parseAiRule(it)?.matcher ?: it.substringBeforeLast(',')) == matcher
        } + rule
        return updated.distinct() to true
    }

    @Synchronized
    internal fun aiRulesSnapshot(context: Context): AiRulesSnapshot {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        ensureLegacyRulesMigrated(home)

        val profile = activeProfile
        val scope = profile?.profileId ?: DEFAULT_RULE_SCOPE
        val source = profile?.yaml
            ?: context.assets.open(BASE_CONFIG).bufferedReader().use { it.readText() }
        val loadedConfigRules = readConfigRules(baseConfigFile(context))
        val policies = policyNamesFromYaml(source)
        val store = readAiRuleStore(scopedAiRulesFile(home, scope))
        val rules = buildList {
            store.enabled.forEach { raw ->
                parseAiRule(raw)?.let { parsed ->
                    add(
                        parsed.toManaged(
                            enabled = true,
                            policyAvailable = parsed.policy in policies,
                            loaded = raw in loadedConfigRules,
                        ),
                    )
                }
            }
            store.disabled.forEach { raw ->
                parseAiRule(raw)?.let { parsed ->
                    add(
                        parsed.toManaged(
                            enabled = false,
                            policyAvailable = parsed.policy in policies,
                            loaded = false,
                        ),
                    )
                }
            }
        }
        return AiRulesSnapshot(
            profileId = scope,
            rules = rules,
            availablePolicies = policies.sortedWith(
                compareBy<String> { it !in BUILT_IN_POLICIES }.thenBy { it.lowercase() },
            ),
        )
    }

    @Synchronized
    internal fun setAiRuleEnabled(context: Context, ruleId: String, enabled: Boolean): Boolean =
        updateAiRuleStore(context) { setRuleEnabled(it, ruleId, enabled) }

    @Synchronized
    internal fun deleteAiRule(context: Context, ruleId: String): Boolean =
        updateAiRuleStore(context) { deleteRule(it, ruleId) }

    @Synchronized
    internal fun deleteAiRuleRaw(context: Context, raw: String): Boolean =
        updateAiRuleStore(context) { deleteRuleByRaw(it, raw) }

    @Synchronized
    internal fun rebindAiRule(context: Context, ruleId: String, newPolicy: String): Boolean {
        val normalizedPolicy = newPolicy.trim()
        if (normalizedPolicy.isEmpty()) return false
        return updateAiRuleStore(context) {
            rebindRule(it, ruleId, normalizedPolicy)
        }
    }

    internal fun setRuleEnabled(
        store: AiRuleStore,
        ruleId: String,
        enabled: Boolean,
    ): AiRuleStore {
        val source = if (enabled) store.disabled else store.enabled
        val rule = source.firstOrNull { parseAiRule(it)?.id == ruleId } ?: return store
        return if (enabled) {
            val (newEnabled, _) = upsertAiRule(store.enabled, rule)
            AiRuleStore(
                enabled = newEnabled,
                disabled = store.disabled.filterNot { parseAiRule(it)?.id == ruleId },
            ).normalized()
        } else {
            AiRuleStore(
                enabled = store.enabled.filterNot { parseAiRule(it)?.id == ruleId },
                disabled = (store.disabled + rule).distinct(),
            ).normalized()
        }
    }

    internal fun deleteRule(store: AiRuleStore, ruleId: String): AiRuleStore =
        AiRuleStore(
            enabled = store.enabled.filterNot { parseAiRule(it)?.id == ruleId },
            disabled = store.disabled.filterNot { parseAiRule(it)?.id == ruleId },
        ).normalized()

    internal fun deleteRuleByRaw(store: AiRuleStore, raw: String): AiRuleStore {
        val normalized = raw.split(',').joinToString(",") { it.trim() }
        val ruleId = parseAiRule(normalized)?.id
        return if (ruleId != null) {
            deleteRule(store, ruleId)
        } else {
            AiRuleStore(
                enabled = store.enabled.filterNot { candidate ->
                    candidate.split(',').joinToString(",") { it.trim() } == normalized
                },
                disabled = store.disabled.filterNot { candidate ->
                    candidate.split(',').joinToString(",") { it.trim() } == normalized
                },
            ).normalized()
        }
    }

    internal fun rebindRule(
        store: AiRuleStore,
        ruleId: String,
        newPolicy: String,
    ): AiRuleStore {
        val enabledRule = store.enabled.firstOrNull { parseAiRule(it)?.id == ruleId }
        val disabledRule = store.disabled.firstOrNull { parseAiRule(it)?.id == ruleId }
        val existing = enabledRule ?: disabledRule ?: return store
        val rebound = replaceRulePolicy(existing, newPolicy) ?: return store
        return if (enabledRule != null) {
            AiRuleStore(
                enabled = store.enabled.map { if (it == existing) rebound else it }.distinct(),
                disabled = store.disabled,
            ).normalized()
        } else {
            AiRuleStore(
                enabled = store.enabled,
                disabled = store.disabled.map { if (it == existing) rebound else it }.distinct(),
            ).normalized()
        }
    }

    private fun updateAiRuleStore(
        context: Context,
        transform: (AiRuleStore) -> AiRuleStore,
    ): Boolean {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        ensureLegacyRulesMigrated(home)
        val file = scopedAiRulesFile(home, activeRuleScope())
        file.parentFile?.mkdirs()
        val before = readAiRuleStore(file)
        val after = transform(before).normalized()
        if (after == before.normalized()) return false
        atomicWrite(file, dumpAiRuleStore(after))
        return true
    }

    fun baseConfigFile(context: Context): File = File(File(context.filesDir, HOME_DIR), BASE_CONFIG)

    /** Policy used by the final MATCH/FINAL rule in the current runtime config. */
    internal fun runtimeDefaultPolicy(context: Context): String? =
        defaultPolicyFromRules(readConfigRules(baseConfigFile(context)))

    internal fun defaultPolicyFromRules(rules: Collection<String>): String? =
        rules.lastOrNull { rule ->
            rule.startsWith("MATCH,") || rule.startsWith("FINAL,")
        }
            ?.substringAfter(',')
            ?.substringBefore(',')
            ?.trim()
            ?.takeIf(String::isNotEmpty)

    /** Returns the AI rule file for the currently active profile. */
    fun aiOverrideFile(context: Context): File {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        ensureLegacyRulesMigrated(home)
        return scopedAiRulesFile(home, activeRuleScope())
    }

    /** Removes only the deleted profile's scoped AI rules. */
    fun deleteProfileAiRules(context: Context, profileId: String) {
        scopedAiRulesFile(File(context.filesDir, HOME_DIR), profileId).delete()
    }

    private fun materializeBaseConfig(context: Context, home: File): File {
        val snapshot = activeProfile
        val source = snapshot?.yaml
            ?: context.assets.open(BASE_CONFIG).bufferedReader().use { it.readText() }
        val scope = snapshot?.profileId ?: DEFAULT_RULE_SCOPE
        val merged = mergeAiRules(source, readAiRuleStore(scopedAiRulesFile(home, scope)).enabled)
        val authenticated = withControllerSecret(
            merged,
            ControllerSecretStore.getOrCreate(context),
            ControllerSecretStore.socketPath(context),
        )
        return File(home, BASE_CONFIG).also { atomicWrite(it, authenticated) }
    }

    private fun activeRuleScope(): String = activeProfile?.profileId ?: DEFAULT_RULE_SCOPE

    internal fun scopedAiRulesFile(home: File, scope: String): File {
        val safeScope = scope.takeIf { SAFE_SCOPE.matches(it) }
            ?: sha256Hex(scope)
        return File(File(home, AI_RULES_DIR), "$safeScope.yaml")
    }

    /**
     * Migrates the former global rule file exactly once. The active profile at
     * upgrade time owns those rules; subsequent profiles always start with an
     * empty independent rule set.
     */
    private fun ensureLegacyRulesMigrated(home: File) {
        migrateLegacyRules(home, activeRuleScope())
    }

    internal fun migrateLegacyRules(home: File, targetScope: String): Boolean {
        val rulesDir = File(home, AI_RULES_DIR).apply { mkdirs() }
        val marker = File(rulesDir, LEGACY_MIGRATION_MARKER)
        if (marker.exists()) return false

        val legacyRules = readAiRuleStore(File(home, AI_OVERRIDE)).enabled
        val target = scopedAiRulesFile(home, targetScope)
        if (legacyRules.isNotEmpty()) {
            val current = readAiRuleStore(target)
            val merged = (current.enabled + legacyRules).distinct()
            atomicWrite(target, dumpAiRuleStore(current.copy(enabled = merged)))
        }
        atomicWrite(marker, targetScope)
        return true
    }

    internal fun mergeAiRules(baseYaml: String, aiRules: List<String>): String {
        val loaded = safeYaml().load<Any?>(baseYaml)
        require(loaded is Map<*, *>) { "Mihomo config root must be a YAML mapping" }

        val config = linkedMapOf<String, Any?>()
        loaded.forEach { (key, value) -> config[key.toString()] = value }
        removeSubscriptionMetadataProxies(config)

        // Profiles generated by older Veer versions have no sniffer block.
        // Enforce it again while materialising the runtime config so AI domain
        // rules also match apps that use an internal DoH resolver and connect
        // directly to real IPs instead of Mihomo fake IPs.
        config["sniffer"] = defaultSnifferConfig()

        // Migrate the original provider-based implementation. A classical provider
        // cannot attach a different policy to each payload entry.
        val providers = (config["rule-providers"] as? Map<*, *>)
            ?.filterKeys { it.toString() != "ai_override_provider" }
        if (providers.isNullOrEmpty()) config.remove("rule-providers")
        else config["rule-providers"] = providers

        val existing = (config["rules"] as? List<*>)
            .orEmpty()
            .mapNotNull { it?.toString() }
            .filterNot { it.startsWith("RULE-SET,ai_override_provider,") }
        val validPolicies = runtimePolicyNames(config)
        val compatibleAiRules = aiRules.filter { rule ->
            rule.substringAfterLast(',', missingDelimiterValue = "") in validPolicies
        }
        config["rules"] = (compatibleAiRules + existing).distinct()
        return yamlDumper().dump(config)
    }

    /** Restricts the final Controller endpoint, including legacy imported profiles. */
    internal fun withControllerSecret(yaml: String, secret: String, socketPath: String): String {
        require(Regex("[0-9a-f]{64}").matches(secret)) { "Invalid Controller credential" }
        require(socketPath.startsWith("/") && !socketPath.contains("..")) {
            "Invalid Controller socket path"
        }
        val loaded = safeYaml().load<Any?>(yaml)
        require(loaded is Map<*, *>) { "Mihomo config root must be a YAML mapping" }
        val config = linkedMapOf<String, Any?>()
        loaded.forEach { (key, value) -> config[key.toString()] = value }
        config.remove("external-controller")
        config.remove("external-controller-tls")
        config.remove("external-controller-pipe")
        config["external-controller-unix"] = socketPath
        config["secret"] = secret
        config["authentication"] = listOf("veer:$secret")
        config["skip-auth-prefixes"] = emptyList<String>()
        val profile = (config["profile"] as? Map<*, *>)
            ?.entries?.associate { it.key.toString() to it.value }?.toMutableMap()
            ?: mutableMapOf()
        profile["store-selected"] = false
        config["profile"] = profile
        return yamlDumper().dump(config)
    }

    private fun defaultSnifferConfig(): LinkedHashMap<String, Any> = linkedMapOf(
        "enable" to true,
        "force-dns-mapping" to true,
        "parse-pure-ip" to true,
        "override-destination" to true,
        "sniff" to linkedMapOf(
            "HTTP" to linkedMapOf(
                "ports" to listOf(80, "8080-8880"),
                "override-destination" to true,
            ),
            "TLS" to linkedMapOf(
                "ports" to listOf(443, 8443),
            ),
            "QUIC" to linkedMapOf(
                "ports" to listOf(443, 8443),
            ),
        ),
    )

    /** Returns policies valid for the active profile; stale rules remain persisted but unloaded. */
    private fun runtimePolicyNames(config: Map<String, Any?>): Set<String> {
        val proxies = (config["proxies"] as? List<*>).orEmpty().mapNotNull { raw ->
            (raw as? Map<*, *>)?.get("name")?.toString()
        }
        val groups = (config["proxy-groups"] as? List<*>).orEmpty().mapNotNull { raw ->
            (raw as? Map<*, *>)?.get("name")?.toString()
        }
        return (proxies + groups + BUILT_IN_POLICIES).toSet()
    }

    /**
     * Migrates already-imported profiles that were generated before metadata
     * rows were filtered by ProfileNormalizer.
     */
    private fun removeSubscriptionMetadataProxies(config: MutableMap<String, Any?>) {
        val proxies = (config["proxies"] as? List<*>).orEmpty()
        val metadataNames = proxies.asSequence()
            .mapNotNull { proxy ->
                (proxy as? Map<*, *>)?.get("name")?.toString()
            }
            .filter(SubscriptionMetadata::isLikelyMetadataName)
            .toSet()
        if (metadataNames.isEmpty()) return

        config["proxies"] = proxies.filterNot { proxy ->
            (proxy as? Map<*, *>)?.get("name")?.toString() in metadataNames
        }
        config["proxy-groups"] = (config["proxy-groups"] as? List<*>).orEmpty().map { rawGroup ->
            val source = rawGroup as? Map<*, *> ?: return@map rawGroup
            val group = linkedMapOf<Any?, Any?>().apply { putAll(source) }
            val members = (source["proxies"] as? List<*>)
                ?.filterNot { it?.toString() in metadataNames }
            if (members != null) group["proxies"] = members.ifEmpty { listOf("DIRECT") }
            group
        }
    }

    internal fun readAiRuleStore(file: File): AiRuleStore {
        if (!file.exists()) return AiRuleStore()
        val enabled = mutableListOf<String>()
        val disabled = mutableListOf<String>()
        var target: MutableList<String>? = null
        file.useLines { lines ->
            lines.forEach { line ->
                val trimmed = line.trim()
                if (line.isNotEmpty() && !line.first().isWhitespace()) {
                    target = when {
                        trimmed.startsWith("payload:") -> enabled
                        trimmed.startsWith("disabled-payload:") -> disabled
                        else -> null
                    }
                    return@forEach
                }
                if (!trimmed.startsWith("- ")) return@forEach
                decodePolicyName(trimmed.removePrefix("- ").trim())
                    .takeIf(String::isNotEmpty)
                    ?.let { target?.add(it) }
            }
        }
        return AiRuleStore(
            enabled = enabled,
            disabled = disabled,
        ).normalized()
    }

    internal fun dumpAiRuleStore(store: AiRuleStore): String =
        yamlDumper().dump(
            linkedMapOf(
                "payload" to store.normalized().enabled,
                "disabled-payload" to store.normalized().disabled,
            ),
        )

    internal fun parseAiRule(raw: String): ParsedAiRule? {
        val parts = raw.split(',').map(String::trim)
        if (parts.size < 3 || parts.any(String::isEmpty)) return null
        val policyIndex = if (parts.last().lowercase() in RULE_MODIFIERS && parts.size >= 4) {
            parts.lastIndex - 1
        } else {
            parts.lastIndex
        }
        if (policyIndex < 2) return null
        val matcher = parts.take(policyIndex).joinToString(",")
        return ParsedAiRule(
            id = sha256Hex(matcher).take(16),
            raw = parts.joinToString(","),
            matchType = parts.first(),
            target = parts.subList(1, policyIndex).joinToString(","),
            policy = parts[policyIndex],
            matcher = matcher,
            policyIndex = policyIndex,
        )
    }

    internal fun replaceRulePolicy(raw: String, newPolicy: String): String? {
        val parsed = parseAiRule(raw) ?: return null
        val parts = parsed.raw.split(',').toMutableList()
        parts[parsed.policyIndex] = newPolicy
        return parts.joinToString(",")
    }

    private fun ParsedAiRule.toManaged(
        enabled: Boolean,
        policyAvailable: Boolean,
        loaded: Boolean,
    ) = ManagedAiRule(
        id = id,
        raw = raw,
        matchType = matchType,
        target = target,
        policy = policy,
        enabled = enabled,
        policyAvailable = policyAvailable,
        loadedInMaterializedConfig = loaded,
    )

    private fun AiRuleStore.normalized(): AiRuleStore {
        val enabledRules = enabled.distinct()
        val enabledIds = enabledRules.mapNotNull { parseAiRule(it)?.id }.toSet()
        return AiRuleStore(
            enabled = enabledRules,
            disabled = disabled.distinct().filterNot { parseAiRule(it)?.id in enabledIds },
        )
    }

    internal fun policyNamesFromYaml(yaml: String): Set<String> {
        val policies = BUILT_IN_POLICIES.toMutableSet()
        var inPolicySection = false
        yaml.lineSequence().forEach { line ->
            val trimmed = line.trim()
            if (line.isNotEmpty() && !line.first().isWhitespace()) {
                inPolicySection = trimmed == "proxies:" || trimmed == "proxy-groups:"
                return@forEach
            }
            if (!inPolicySection) return@forEach
            val rawName = POLICY_NAME_LINE.matchEntire(line)?.groupValues?.get(1)?.trim()
                ?: return@forEach
            val name = decodePolicyName(rawName)
            if (name.isNotEmpty()) policies += name
        }
        return policies
    }

    private fun decodePolicyName(raw: String): String = when {
        raw.length >= 2 && raw.first() == '\'' && raw.last() == '\'' ->
            raw.substring(1, raw.lastIndex).replace("''", "'")
        raw.length >= 2 && raw.first() == '"' && raw.last() == '"' ->
            runCatching { safeYaml().load<Any?>(raw)?.toString() }
                .getOrNull()
                .orEmpty()
        else -> raw.substringBefore(" #").trim()
    }

    private fun readConfigRules(file: File): Set<String> {
        if (!file.exists()) return emptySet()
        val rules = mutableSetOf<String>()
        var inRules = false
        file.useLines { lines ->
            lines.forEach { line ->
                val trimmed = line.trim()
                if (line.isNotEmpty() && !line.first().isWhitespace()) {
                    inRules = trimmed == "rules:"
                    return@forEach
                }
                if (!inRules || !trimmed.startsWith("- ")) return@forEach
                decodePolicyName(trimmed.removePrefix("- ").trim())
                    .takeIf(String::isNotEmpty)
                    ?.let(rules::add)
            }
        }
        return rules
    }

    private fun safeYaml() = Yaml(SafeConstructor(LoaderOptions()))

    private fun yamlDumper(): Yaml {
        val options = DumperOptions().apply {
            defaultFlowStyle = DumperOptions.FlowStyle.BLOCK
            indent = 4
            indicatorIndent = 2
            isPrettyFlow = false
        }
        return Yaml(options)
    }

    private fun copyAsset(context: Context, assetName: String, target: File, overwrite: Boolean) {
        if (target.exists() && !overwrite) return
        val temporary = File(target.parentFile, ".${target.name}.${UUID.randomUUID()}.tmp")
        try {
            context.assets.open(assetName).use { input ->
                temporary.outputStream().use { output -> input.copyTo(output) }
            }
            moveIntoPlace(temporary, target)
        } finally {
            temporary.delete()
        }
    }

    private fun atomicWrite(target: File, content: String) {
        val temporary = File(target.parentFile, ".${target.name}.${UUID.randomUUID()}.tmp")
        try {
            temporary.outputStream().bufferedWriter(Charsets.UTF_8).use { it.write(content) }
            moveIntoPlace(temporary, target)
        } finally {
            temporary.delete()
        }
    }

    private fun moveIntoPlace(source: File, target: File) {
        runCatching {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE,
            )
        }.getOrElse {
            Files.move(
                source.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        }
    }

    private fun sha256Hex(text: String): String =
        java.security.MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }

    private val SAFE_SCOPE = Regex("""[A-Za-z0-9._-]{1,128}""")
    private val RULE_MODIFIERS = setOf("no-resolve", "src")
    private val POLICY_NAME_LINE = Regex("""\s*-\s*name:\s*(.+)\s*""")
    private val BUILT_IN_POLICIES = setOf(
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE",
    )
}
