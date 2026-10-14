package com.yamax.veer.core_mihomo

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions
import java.security.SecureRandom
import java.util.UUID

/** One app-private Controller credential shared by the UI and :veercore processes. */
internal object ControllerSecretStore {
    private const val FILE_NAME = "controller-secret"
    private val validSecret = Regex("[0-9a-f]{64}")

    @Volatile private var directory: File? = null

    fun initialize(context: Context) {
        directory = File(context.noBackupFilesDir, "mihomo-auth")
    }

    fun getOrCreate(context: Context): String =
        getOrCreate(File(context.noBackupFilesDir, "mihomo-auth"))

    fun getOrCreate(): String = getOrCreate(
        requireNotNull(directory) { "ControllerSecretStore has not been initialized" },
    )

    fun socketPath(context: Context): String =
        File(File(context.noBackupFilesDir, "mihomo-auth"), "controller.sock").absolutePath

    fun socketPath(): String = File(
        requireNotNull(directory) { "ControllerSecretStore has not been initialized" },
        "controller.sock",
    ).absolutePath

    @Synchronized
    internal fun getOrCreate(directory: File): String {
        check(directory.isDirectory || directory.mkdirs()) { "Cannot create Controller credential directory" }
        Files.setPosixFilePermissions(
            directory.toPath(),
            PosixFilePermissions.fromString("rwx------"),
        )
        val lockFile = File(directory, "$FILE_NAME.lock")
        RandomAccessFile(lockFile, "rw").use { lockHandle ->
            lockHandle.channel.lock().use {
                val secretFile = File(directory, FILE_NAME)
                val existing = secretFile.takeIf(File::isFile)?.readText()?.trim()
                if (existing != null && validSecret.matches(existing)) return existing

                val random = ByteArray(32).also(SecureRandom()::nextBytes)
                val secret = random.joinToString("") { "%02x".format(it) }
                val temp = File(directory, "$FILE_NAME.${UUID.randomUUID()}.tmp")
                try {
                    FileOutputStream(temp).use { output ->
                        output.write(secret.toByteArray(Charsets.US_ASCII))
                        output.fd.sync()
                    }
                    Files.move(
                        temp.toPath(), secretFile.toPath(),
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING,
                    )
                } finally {
                    temp.delete()
                }
                return secret
            }
        }
    }
}
