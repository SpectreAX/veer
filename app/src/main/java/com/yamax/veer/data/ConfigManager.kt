package com.yamax.veer.data

import android.content.Context
import java.io.File
import java.io.IOException

/**
 * Copies the bundled Mihomo assets into the app's internal storage so the Go
 * core (which only accepts filesystem paths) can read them.
 *
 * The home directory layout after [prepare] is:
 *
 * ```
 * <filesDir>/mihomo/
 *   base.yaml         # canonical config, overwritten on every launch
 *   ai_override.yaml  # writable rule-provider; preserved across launches
 * ```
 */
object ConfigManager {

    private const val HOME_DIR = "mihomo"
    const val BASE_CONFIG = "base.yaml"
    const val AI_OVERRIDE = "ai_override.yaml"

    /**
     * Set by ProfileManager before [prepare] runs. When non-null, this YAML is
     * written to base.yaml instead of the bundled asset, so the active profile's
     * config is used without a file-read race at service start.
     */
    @Volatile var activeProfileYaml: String? = null

    /**
     * Materialises the Mihomo home directory and returns it.
     *
     * `base.yaml` is overwritten on every call: either with [activeProfileYaml]
     * when a profile is active, or with the bundled asset otherwise.
     * `ai_override.yaml` is only seeded if it doesn't already exist.
     */
    @Throws(IOException::class)
    fun prepare(context: Context): File {
        val home = File(context.filesDir, HOME_DIR).apply { mkdirs() }
        val profileYaml = activeProfileYaml
        if (profileYaml != null) {
            File(home, BASE_CONFIG).writeText(profileYaml)
        } else {
            copyAsset(context, BASE_CONFIG, File(home, BASE_CONFIG), overwrite = true)
        }
        copyAsset(context, AI_OVERRIDE, File(home, AI_OVERRIDE), overwrite = false)
        return home
    }

    fun baseConfigFile(context: Context): File = File(File(context.filesDir, HOME_DIR), BASE_CONFIG)

    fun aiOverrideFile(context: Context): File = File(File(context.filesDir, HOME_DIR), AI_OVERRIDE)

    private fun copyAsset(context: Context, assetName: String, target: File, overwrite: Boolean) {
        if (target.exists() && !overwrite) return
        context.assets.open(assetName).use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
    }
}
