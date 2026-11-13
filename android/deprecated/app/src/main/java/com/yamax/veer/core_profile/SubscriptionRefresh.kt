package com.yamax.veer.core_profile

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.yamax.veer.core_logging.VeerLog
import com.yamax.veer.core_profile.internal.parser.ImportResult
import com.yamax.veer.core_profile.internal.parser.message
import com.yamax.veer.core_profile.internal.storage.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.TimeUnit

@Serializable
internal enum class SubscriptionRefreshOutcome {
    UPDATED,
    UNCHANGED,
    FAILED,
}

@Serializable
internal data class SubscriptionDiffSummary(
    val proxiesAdded: Int,
    val proxiesRemoved: Int,
    val groupsAdded: Int,
    val groupsRemoved: Int,
    val rulesAdded: Int,
    val rulesRemoved: Int,
    val configChanged: Boolean,
) {
    companion object {
        fun between(before: ProfileMetadata, after: ProfileMetadata) =
            SubscriptionDiffSummary(
                proxiesAdded = (after.proxyCount - before.proxyCount).coerceAtLeast(0),
                proxiesRemoved = (before.proxyCount - after.proxyCount).coerceAtLeast(0),
                groupsAdded = (after.groupCount - before.groupCount).coerceAtLeast(0),
                groupsRemoved = (before.groupCount - after.groupCount).coerceAtLeast(0),
                rulesAdded = (after.ruleCount - before.ruleCount).coerceAtLeast(0),
                rulesRemoved = (before.ruleCount - after.ruleCount).coerceAtLeast(0),
                configChanged = before.configHashSha256 != after.configHashSha256,
            )
    }
}

@Serializable
internal data class SubscriptionRefreshRecord(
    val id: String = UUID.randomUUID().toString(),
    val profileId: String,
    val displayName: String,
    val startedAtMs: Long,
    val completedAtMs: Long,
    val outcome: SubscriptionRefreshOutcome,
    val diff: SubscriptionDiffSummary? = null,
    val error: String? = null,
    val workerAttempt: Int = 0,
)

internal data class SubscriptionRefreshBatchResult(
    val updated: Int,
    val unchanged: Int,
    val failed: Int,
) {
    val shouldRetry: Boolean get() = failed > 0 && updated == 0 && unchanged == 0
}

internal object SubscriptionRefreshHistory {
    private const val MAX_RECORDS = 50
    private val mutex = Mutex()
    private val json = Json {
        prettyPrint = true
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    private val _records = MutableStateFlow<List<SubscriptionRefreshRecord>>(emptyList())
    val records: StateFlow<List<SubscriptionRefreshRecord>> = _records.asStateFlow()

    fun init(context: Context) {
        _records.value = loadSync(context.applicationContext)
    }

    suspend fun append(context: Context, record: SubscriptionRefreshRecord) {
        withContext(Dispatchers.IO) {
            mutex.withLock {
                val updated = (listOf(record) + loadSync(context))
                    .distinctBy { it.id }
                    .take(MAX_RECORDS)
                atomicWrite(historyFile(context), json.encodeToString(updated))
                _records.value = updated
            }
        }
    }

    private fun loadSync(context: Context): List<SubscriptionRefreshRecord> {
        val file = historyFile(context)
        if (!file.exists()) return emptyList()
        return runCatching {
            json.decodeFromString<List<SubscriptionRefreshRecord>>(file.readText())
        }.getOrDefault(emptyList())
    }

    private fun historyFile(context: Context) =
        File(context.filesDir, "profiles/subscription_refresh_history.json")

    private fun atomicWrite(target: File, content: String) {
        target.parentFile?.mkdirs()
        val temporary = File(target.parentFile, ".${target.name}.${UUID.randomUUID()}.tmp")
        try {
            temporary.writeText(content)
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

internal object SubscriptionRefreshManager {
    private val refreshMutex = Mutex()

    suspend fun refreshAll(context: Context, workerAttempt: Int = 0):
        SubscriptionRefreshBatchResult = refreshMutex.withLock {
        val appContext = context.applicationContext
        val subscriptions = ProfileStore.loadIndex(appContext).profiles
            .filter { it.source is ProfileSource.SubscriptionUrl }
        var updated = 0
        var unchanged = 0
        var failed = 0

        for (before in subscriptions) {
            val started = System.currentTimeMillis()
            when (val result = ProfileManager.refreshInBackground(appContext, before.id)) {
                is ImportResult.Success -> {
                    val after = ProfileStore.loadIndex(appContext).profiles
                        .find { it.id == before.id }
                        ?: before
                    val diff = SubscriptionDiffSummary.between(before, after)
                    val outcome = if (diff.configChanged) {
                        updated += 1
                        SubscriptionRefreshOutcome.UPDATED
                    } else {
                        unchanged += 1
                        SubscriptionRefreshOutcome.UNCHANGED
                    }
                    SubscriptionRefreshHistory.append(
                        appContext,
                        SubscriptionRefreshRecord(
                            profileId = before.id.value,
                            displayName = before.displayName,
                            startedAtMs = started,
                            completedAtMs = System.currentTimeMillis(),
                            outcome = outcome,
                            diff = diff,
                            workerAttempt = workerAttempt,
                        ),
                    )
                }
                is ImportResult.Failure -> {
                    failed += 1
                    val error = sanitizeError(
                        result.errors.joinToString("; ") { it.message() },
                    )
                    SubscriptionRefreshHistory.append(
                        appContext,
                        SubscriptionRefreshRecord(
                            profileId = before.id.value,
                            displayName = before.displayName,
                            startedAtMs = started,
                            completedAtMs = System.currentTimeMillis(),
                            outcome = SubscriptionRefreshOutcome.FAILED,
                            error = error,
                            workerAttempt = workerAttempt,
                        ),
                    )
                    VeerLog.profile(
                        "scheduled refresh failed profile=${before.id.value}: $error",
                        VeerLog.Level.WARN,
                    )
                }
            }
        }
        SubscriptionRefreshBatchResult(updated, unchanged, failed)
    }

    internal fun sanitizeError(value: String): String = value
        .replace(Regex("""https?://[^\s,;]+"""), "[redacted-url]")
        .replace(Regex("""(?i)(token|key|secret|password)=([^&\s]+)"""), "$1=[redacted]")
        .take(300)
}

internal class SubscriptionRefreshWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {
    override suspend fun doWork(): Result {
        val result = SubscriptionRefreshManager.refreshAll(
            applicationContext,
            workerAttempt = runAttemptCount,
        )
        VeerLog.profile(
            "scheduled refresh complete updated=${result.updated} " +
                "unchanged=${result.unchanged} failed=${result.failed}",
        )
        return if (result.shouldRetry && runAttemptCount < MAX_RETRIES) {
            Result.retry()
        } else {
            Result.success()
        }
    }

    companion object {
        private const val MAX_RETRIES = 3
    }
}

internal object SubscriptionRefreshScheduler {
    private const val PERIODIC_WORK_NAME = "subscription-refresh-periodic"
    private const val IMMEDIATE_WORK_NAME = "subscription-refresh-immediate"

    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<SubscriptionRefreshWorker>(
            24,
            TimeUnit.HOURS,
            2,
            TimeUnit.HOURS,
        )
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
            .addTag(PERIODIC_WORK_NAME)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
            PERIODIC_WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request,
        )
    }

    fun enqueueNow(context: Context) {
        val request = OneTimeWorkRequestBuilder<SubscriptionRefreshWorker>()
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.MINUTES)
            .addTag(IMMEDIATE_WORK_NAME)
            .build()
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            IMMEDIATE_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            request,
        )
    }
}
