package com.yamax.veer.testing

import android.content.Context
import android.content.res.Configuration
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.yamax.veer.R
import com.yamax.veer.data.ManagedAiRule
import com.yamax.veer.ui.resolve
import com.yamax.veer.ui.nodes.delayPresentation
import com.yamax.veer.ui.rules.aiRulePresentation
import com.yamax.veer.ui.uiText
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalizedResourcesInstrumentedTest {
    @Test
    fun englishAndChineseResourcesResolveWithEquivalentFormatting() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val english = base.withLocale(Locale.ENGLISH)
        val chinese = base.withLocale(Locale.SIMPLIFIED_CHINESE)

        assertEquals("Settings", english.getString(R.string.settings_title))
        assertEquals("设置", chinese.getString(R.string.settings_title))
        assertNotEquals(
            english.getString(R.string.home_quick_actions),
            chinese.getString(R.string.home_quick_actions),
        )

        val englishTraffic = english.getString(
            R.string.connection_traffic,
            "1 MB",
            "2 MB",
            3,
            4,
        )
        val chineseTraffic = chinese.getString(
            R.string.connection_traffic,
            "1 MB",
            "2 MB",
            3,
            4,
        )
        listOf(englishTraffic, chineseTraffic).forEach { value ->
            assertTrue("1 MB" in value)
            assertTrue("2 MB" in value)
            assertTrue("3" in value)
            assertTrue("4" in value)
        }
    }

    @Test
    fun profileUiTextResolvesArgumentsAndNestedResourcesInBothLocales() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val english = base.withLocale(Locale.ENGLISH)
        val chinese = base.withLocale(Locale.SIMPLIFIED_CHINESE)
        val message = uiText(
            R.string.profile_rolled_back,
            uiText(R.string.profile_failure_stage_start_timeout),
        )

        assertEquals(
            "Selected profile failed during the startup timeout. " +
                "Veer restored the last working profile and reconnected.",
            message.resolve(english),
        )
        assertEquals(
            "所选配置在启动超时阶段失败。Veer 已恢复上一个可用配置并重新连接。",
            message.resolve(chinese),
        )
        assertEquals("Saved profiles (3)", english.getString(R.string.profile_saved_count, 3))
        assertEquals("已保存配置（3）", chinese.getString(R.string.profile_saved_count, 3))
    }

    @Test
    fun dnsResourcesResolveValidationAndNestedRuntimeStateInBothLocales() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val english = base.withLocale(Locale.ENGLISH)
        val chinese = base.withLocale(Locale.SIMPLIFIED_CHINESE)
        val runtimeMessage = uiText(
            R.string.dns_runtime_busy,
            uiText(R.string.dns_state_stopping),
        )

        assertEquals(
            "The VPN is stopping. Wait for a stable state and try again.",
            runtimeMessage.resolve(english),
        )
        assertEquals(
            "VPN 当前为停止中，请等待状态稳定后重试。",
            runtimeMessage.resolve(chinese),
        )
        assertEquals(
            "• Primary DNS, line 2: Not a valid DNS address",
            english.getString(
                R.string.dns_validation_bullet,
                english.getString(R.string.dns_validation_field_primary),
                english.getString(R.string.dns_validation_line, 2),
                english.getString(R.string.dns_validation_invalid_address),
            ),
        )
        assertEquals(
            "• 主要 DNS（第 2 行）：不是有效的 DNS 地址",
            chinese.getString(
                R.string.dns_validation_bullet,
                chinese.getString(R.string.dns_validation_field_primary),
                chinese.getString(R.string.dns_validation_line, 2),
                chinese.getString(R.string.dns_validation_invalid_address),
            ),
        )
    }

    @Test
    fun rulePresentationLocalizesDescriptionsWithoutChangingRuleValues() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val english = base.withLocale(Locale.ENGLISH)
        val chinese = base.withLocale(Locale.SIMPLIFIED_CHINESE)
        val presentation = aiRulePresentation(
            ManagedAiRule(
                id = "locale-rule",
                raw = "GEOSITE,netflix,HK",
                matchType = "GEOSITE",
                target = "netflix",
                policy = "HK",
                enabled = true,
                policyAvailable = true,
                loadedInMaterializedConfig = true,
            ),
        )

        assertEquals("Netflix → Hong Kong (HK)", presentation.routeSummary.resolve(english))
        assertEquals("Netflix → 香港（HK）", presentation.routeSummary.resolve(chinese))
        assertEquals(
            "Service traffic · GEOSITE/netflix",
            presentation.matchDescription.resolve(english),
        )
        assertEquals(
            "服务流量 · GEOSITE/netflix",
            presentation.matchDescription.resolve(chinese),
        )
    }

    @Test
    fun nodeDelayAndSelectionMessagesLocalizeWithoutChangingNodeNames() {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val english = base.withLocale(Locale.ENGLISH)
        val chinese = base.withLocale(Locale.SIMPLIFIED_CHINESE)
        val timeout = delayPresentation(65_535, false).text
        val selected = uiText(
            R.string.nodes_auto_switched_delay,
            "PROXY",
            "Tokyo A",
            42,
        )

        assertEquals("Timeout", timeout.resolve(english))
        assertEquals("超时", timeout.resolve(chinese))
        assertEquals(
            "PROXY automatically switched to Tokyo A (42 ms)",
            selected.resolve(english),
        )
        assertEquals(
            "PROXY 已自动切换到 Tokyo A（42 ms）",
            selected.resolve(chinese),
        )
    }

    private fun Context.withLocale(locale: Locale): Context {
        val configuration = Configuration(resources.configuration)
        configuration.setLocale(locale)
        return createConfigurationContext(configuration)
    }
}
