package com.yamax.veer.core_mihomo

import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicReference

/**
 * Stable Java-to-Go JNI entry thread for the embedded Mihomo runtime.
 *
 * gomobile attaches a Go goroutine to every Java thread that enters the
 * binding. Android pools (and especially one-off Thread instances) therefore
 * make repeated lifecycle and stats calls look like a growing set of
 * `runtime.goexit [locked to thread]` goroutines. A single daemon executor
 * keeps that attachment bounded and also preserves native call ordering.
 */
internal object VeercoreNativeExecutor {
    private const val THREAD_NAME = "veercore-native"
    private val worker = AtomicReference<Thread?>()
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, THREAD_NAME).apply {
            isDaemon = true
            worker.set(this)
        }
    }

    fun <T> call(block: () -> T): T {
        if (Thread.currentThread() === worker.get()) {
            return block()
        }
        return await(submit(block))
    }

    fun <T> submit(block: () -> T): Future<T> =
        executor.submit(Callable { block() })

    private fun <T> await(future: Future<T>): T {
        try {
            return future.get()
        } catch (e: ExecutionException) {
            throw e.cause ?: e
        }
    }
}
