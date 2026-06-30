import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Read DEEPSEEK_API_KEY from local.properties (preferred) or env so the key
// never lands in version control. Empty string is a valid build — the UI will
// surface a clear "API key missing" error at runtime instead of crashing.
val deepseekApiKey: String = run {
    val local = rootProject.file("local.properties")
    val fromProps = if (local.exists()) {
        Properties().apply { local.inputStream().use { load(it) } }.getProperty("deepseek.api.key").orEmpty()
    } else ""
    fromProps.ifEmpty { System.getenv("DEEPSEEK_API_KEY").orEmpty() }
}

android {
    namespace = "com.yamax.veer"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

    defaultConfig {
        applicationId = "com.yamax.veer"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // Mihomo + gomobile only ship arm64 / armeabi binaries we care about.
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }

        buildConfigField("String", "DEEPSEEK_API_KEY", "\"$deepseekApiKey\"")
    }

    buildTypes {
        debug {
            // Enables the Go fault-injection layer in the debug .aar and the
            // Kotlin-side PhaseTrace / FaultInjector infrastructure.
            buildConfigField("boolean", "FAULT_INJECT", "true")
        }
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            buildConfigField("boolean", "FAULT_INJECT", "false")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        // gomobile aars sometimes ship duplicate license / kotlin metadata.
        resources.excludes += listOf(
            "/META-INF/{AL2.0,LGPL2.1}",
            "/META-INF/LICENSE*",
            "/META-INF/NOTICE*",
        )
    }
}

// ---------------------------------------------------------------------------
// Geo-database asset refresh
// ---------------------------------------------------------------------------
// Run once to (re-)download the latest Mihomo geo databases into assets/:
//
//   ./gradlew downloadGeoAssets
//
// Source URLs (GitHub releases via ghproxy.net for CN accessibility):
//   geoip.metadb → github.com/MetaCubeX/meta-rules-dat releases/latest
//   geosite.dat  → github.com/MetaCubeX/meta-rules-dat releases/latest
//
// After running, commit the updated binary files and bump geo_version.txt
// (date format YYYY-MM-DD). GeoDatabaseManager copies them on first install
// and on each APK update that carries a new version string.
tasks.register("downloadGeoAssets") {
    group = "assets"
    description = "Downloads latest Mihomo geo databases into app/src/main/assets/."

    doLast {
        val assetsDir = file("src/main/assets").also { it.mkdirs() }
        // Update this string each time you run downloadGeoAssets so GeoDatabaseManager
        // knows to re-copy the new bundle on next launch (format: YYYY-MM-DD).
        val today = "2026-05-26"

        data class GeoFile(val name: String, val mirrors: List<String>)
        val geoFiles = listOf(
            GeoFile(
                "geoip.metadb",
                listOf(
                    "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb",
                    "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
                    "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
                    "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb",
                )
            ),
            GeoFile(
                "geosite.dat",
                listOf(
                    "https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat",
                    "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
                    "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
                    "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat",
                )
            ),
        )

        for (geo in geoFiles) {
            var saved = false
            for (url in geo.mirrors) {
                runCatching {
                    println("[downloadGeoAssets] ${geo.name} ← $url")
                    val conn = uri(url).toURL().openConnection().apply {
                        connectTimeout = 15_000
                        readTimeout    = 120_000
                        setRequestProperty("User-Agent", "Gradle/downloadGeoAssets")
                    }
                    val bytes = conn.getInputStream().use { it.readBytes() }
                    if (bytes.size < 100_000)
                        error("response too small: ${bytes.size} bytes")
                    file("$assetsDir/${geo.name}").writeBytes(bytes)
                    println("[downloadGeoAssets] ✓ ${geo.name} saved (${bytes.size} bytes)")
                    saved = true
                }.onFailure { e -> println("[downloadGeoAssets] ✗ $url — ${e.message}") }
                if (saved) break
            }
            if (!saved) throw GradleException("Failed to download ${geo.name} from all mirrors")
        }

        file("$assetsDir/geo_version.txt").writeText(today)
        println("[downloadGeoAssets] geo_version.txt = $today — commit assets/ and bump versionCode")
    }
}

dependencies {
    // Release builds use the production .aar (no fault injection symbols).
    // Debug builds prefer libveer_core_debug.aar when it exists (built with
    // `make aar-debug` in go_core/); fall back to the production .aar so the
    // project compiles even without a debug .aar present.
    val debugAar = file("libs/libveer_core_debug.aar")
    releaseImplementation(fileTree("libs") { include("libveer_core.aar", "*.jar") })
    debugImplementation(
        if (debugAar.exists()) files(debugAar) + fileTree("libs") { include("*.jar") }
        else fileTree("libs") { include("libveer_core.aar", "*.jar") }
    )

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.okhttp.brotli)
    implementation(libs.snakeyaml)
    testImplementation(libs.junit)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.kotlinx.coroutines.test)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    debugImplementation(libs.androidx.compose.ui.tooling)
}
