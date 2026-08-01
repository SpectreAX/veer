package com.yamax.veer.core_profile.internal.parser

import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_profile.ProfileId
import com.yamax.veer.core_profile.ProfileMetadata
import com.yamax.veer.core_profile.ProfileSource
import com.yamax.veer.core_profile.SubscriptionUsage
import com.yamax.veer.core_profile.internal.generator.RuntimeConfigGenerator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Orchestrates the full import pipeline:
 *
 *   [ProfileInput]
 *     → fetch / decode raw YAML bytes
 *     → parse YAML into [ImportedProfile]
 *     → validate
 *     → normalize
 *     → generate runtime YAML
 *     → [ImportResult]
 *
 * All CPU-bound steps run on [Dispatchers.Default]; I/O on [Dispatchers.IO].
 */
internal object ProfileParser {

    suspend fun parse(
        input: ProfileInput,
        displayName: String = "",
        id: ProfileId = ProfileId.generate(),
        cacheDir: File? = null,
    ): ImportResult {
        val log = ImportLogBuilder()

        val policyError = when (input) {
            is ProfileInput.SubscriptionUrl -> ProfileImportPolicy.validateSubscriptionUrl(input.url)
            is ProfileInput.YamlBytes -> if (input.bytes.size > ProfileImportPolicy.MAX_PROFILE_BYTES) {
                ValidationError.ProfileTooLarge(ProfileImportPolicy.MAX_PROFILE_BYTES)
            } else null
            is ProfileInput.Base64Text -> if (input.encoded.length > ProfileImportPolicy.MAX_PROFILE_BYTES * 2) {
                ValidationError.ProfileTooLarge(ProfileImportPolicy.MAX_PROFILE_BYTES)
            } else null
        }
        if (policyError != null) {
            log.log(PipelineStage.FETCH, LogLevel.ERROR, policyError.message())
            return ImportResult.Failure(listOf(policyError), log.build())
        }

        return withContext(Dispatchers.Default) {
            // Top-level guard: no exception may escape parse(). CancellationException
            // is re-thrown so coroutine cancellation is not accidentally swallowed.
            try {
                // 1. Fetch / decode
                log.beginStage(PipelineStage.FETCH)
                val fetched = when (val r = fetchRawYaml(input, log, cacheDir)) {
                    is FetchResult.Ok       -> r
                    is FetchResult.AntiBotError -> return@withContext ImportResult.Failure(
                        errors = listOf(
                            ValidationError.AntiBotBlock(
                                category      = r.result.category,
                                statusCode    = r.result.statusCode,
                                finalHost     = r.result.finalHost,
                                redirectCount = r.result.redirectCount,
                            )
                        ),
                        log = log.build(),
                    )
                    is FetchResult.Error    -> return@withContext ImportResult.Failure(
                        errors = listOf(ValidationError.MalformedYaml(r.message)),
                        log    = log.build(),
                    )
                }
                val rawYaml = fetched.yaml
                val source = fetched.source
                log.endStage(PipelineStage.FETCH)

                // 2. Parse YAML
                log.beginStage(PipelineStage.YAML_PARSE)
                val resolvedName = displayName.ifBlank { inferName(input, source) }
                val parseResult = ClashYamlParser.parse(rawYaml, id, source, resolvedName)
                if (parseResult.isFailure) {
                    val msg = parseResult.exceptionOrNull()?.message ?: "unknown parse error"
                    log.log(PipelineStage.YAML_PARSE, LogLevel.ERROR, msg)
                    return@withContext ImportResult.Failure(
                        errors = listOf(ValidationError.MalformedYaml(msg)),
                        log    = log.build(),
                    )
                }
                val parsed = parseResult.getOrThrow()
                log.log(PipelineStage.YAML_PARSE, LogLevel.INFO,
                    "parsed ${parsed.proxies.size} proxies, ${parsed.proxyGroups.size} groups, ${parsed.rules.size} rules")
                log.endStage(PipelineStage.YAML_PARSE)

                // 3. Validate
                log.beginStage(PipelineStage.VALIDATE)
                val errors = ProfileValidator.validate(parsed)
                if (errors.isNotEmpty()) {
                    errors.forEach { log.log(PipelineStage.VALIDATE, LogLevel.ERROR, it.message()) }
                    return@withContext ImportResult.Failure(errors = errors, log = log.build())
                }
                log.endStage(PipelineStage.VALIDATE)

                // 4. Normalize
                log.beginStage(PipelineStage.NORMALIZE)
                val normalized = ProfileNormalizer.normalize(parsed)
                log.log(PipelineStage.NORMALIZE, LogLevel.INFO,
                    "normalized: ${normalized.proxies.size} proxies" +
                        " ${normalized.proxyGroups.size} groups ${normalized.rules.size} rules")
                log.endStage(PipelineStage.NORMALIZE)

                // 5. Generate runtime config
                log.beginStage(PipelineStage.GENERATE_CONFIG)
                val generateResult = RuntimeConfigGenerator.generate(normalized)
                if (generateResult.isFailure) {
                    val msg = generateResult.exceptionOrNull()?.message ?: "config generation failed"
                    log.log(PipelineStage.GENERATE_CONFIG, LogLevel.ERROR, msg)
                    return@withContext ImportResult.Failure(
                        errors = listOf(ValidationError.MalformedYaml("Config generation failed: $msg")),
                        log    = log.build(),
                    )
                }
                val generated = generateResult.getOrThrow()
                log.log(PipelineStage.GENERATE_CONFIG, LogLevel.INFO,
                    "generated config hash=${generated.sha256Hex.take(8)}… (round-trip validated)")
                log.endStage(PipelineStage.GENERATE_CONFIG)

                // Stamp hash into metadata
                val finalProfile = normalized.copy(
                    metadata = normalized.metadata.copy(
                        configHashSha256 = generated.sha256Hex,
                        subscriptionUsage = fetched.subscriptionUsage,
                    )
                )

                ImportResult.Success(
                    profile       = finalProfile,
                    rawYaml       = rawYaml,
                    generatedYaml = generated.yaml,
                    log           = log.build(),
                )
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                val msg = "${e.javaClass.simpleName}: ${e.message ?: e.toString()}"
                log.log(PipelineStage.GENERATE_CONFIG, LogLevel.ERROR, "uncaught exception: $msg")
                VeerLog.parser("[parser] uncaught exception: $msg")
                ImportResult.Failure(
                    errors = listOf(ValidationError.MalformedYaml("Unexpected error: $msg")),
                    log    = log.build(),
                )
            }
        }
    }

    // -------------------------------------------------------------------------
    // Fetch helpers
    // -------------------------------------------------------------------------

    private sealed class FetchResult {
        data class Ok(
            val yaml: String,
            val source: ProfileSource,
            val subscriptionUsage: SubscriptionUsage? = null,
        ) : FetchResult()
        data class AntiBotError(val result: SubscriptionFetchResult.AntiBotDetected) : FetchResult()
        data class Error(val message: String) : FetchResult()
    }

    private suspend fun fetchRawYaml(
        input: ProfileInput,
        log: ImportLogBuilder,
        cacheDir: File? = null,
    ): FetchResult {
        return when (input) {
            is ProfileInput.YamlBytes -> {
                log.log(PipelineStage.FETCH, LogLevel.INFO, "reading file: ${input.fileName}")
                FetchResult.Ok(
                    yaml   = String(input.bytes, Charsets.UTF_8),
                    source = ProfileSource.ClashFile(input.fileName, input.bytes.size.toLong()),
                )
            }

            is ProfileInput.SubscriptionUrl -> {
                val host = runCatching { java.net.URL(input.url).host }.getOrDefault("unknown")
                log.log(PipelineStage.FETCH, LogLevel.INFO, "fetching subscription host=$host")
                when (val result = UrlFetcher.fetch(input.url, cacheDir)) {
                    is SubscriptionFetchResult.Failed        ->
                        return FetchResult.Error("fetch failed: ${result.message}")

                    is SubscriptionFetchResult.AntiBotDetected ->
                        return FetchResult.AntiBotError(result)

                    is SubscriptionFetchResult.Success -> {
                        val text = String(result.bytes, Charsets.UTF_8)
                        val yaml = if (looksLikeBase64(text)) {
                            log.log(PipelineStage.FETCH, LogLevel.DEBUG, "response appears base64-encoded")
                            Base64Decoder.decode(text).getOrDefault(text)
                        } else text
                        if (yaml.toByteArray(Charsets.UTF_8).size > ProfileImportPolicy.MAX_PROFILE_BYTES) {
                            return FetchResult.Error("response exceeds the 10 MiB profile limit")
                        }
                        FetchResult.Ok(
                            yaml   = yaml,
                            source = ProfileSource.SubscriptionUrl(input.url, System.currentTimeMillis()),
                            subscriptionUsage = result.subscriptionUsage,
                        )
                    }
                }
            }

            is ProfileInput.Base64Text -> {
                log.log(PipelineStage.DECODE, LogLevel.INFO, "decoding base64 (${input.encoded.length} chars)")
                val decoded = Base64Decoder.decode(input.encoded)
                if (decoded.isFailure) {
                    return FetchResult.Error("base64 decode failed: ${decoded.exceptionOrNull()?.message}")
                }
                val yaml = decoded.getOrThrow()
                if (yaml.toByteArray(Charsets.UTF_8).size > ProfileImportPolicy.MAX_PROFILE_BYTES) {
                    return FetchResult.Error("decoded profile exceeds the 10 MiB profile limit")
                }
                FetchResult.Ok(
                    yaml   = yaml,
                    source = ProfileSource.Base64Text(input.encoded.length),
                )
            }
        }
    }

    private fun looksLikeBase64(text: String): Boolean {
        val trimmed = text.trim()
        if (trimmed.length < 20) return false
        val base64Chars = Regex("[A-Za-z0-9+/=\\-_\\s]+")
        return base64Chars.matches(trimmed) && !trimmed.startsWith("proxies")
    }

    private fun inferName(input: ProfileInput, source: ProfileSource): String = when (input) {
        is ProfileInput.YamlBytes       -> input.fileName.removeSuffix(".yaml").removeSuffix(".yml")
        is ProfileInput.SubscriptionUrl -> input.url.substringAfterLast('/').ifBlank { input.url.substringAfterLast("//").substringBefore('/') }
        is ProfileInput.Base64Text      -> "Imported Profile"
    }
}
