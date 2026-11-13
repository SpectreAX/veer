package com.yamax.veer.core_profile

/**
 * Detects provider status rows that masquerade as proxy nodes.
 *
 * Some subscriptions encode quota, expiry, website, or troubleshooting text
 * as syntactically valid Trojan/VLESS proxies. Leaving those rows in URLTest
 * and Fallback groups can make Mihomo select a non-proxy host and take the
 * whole device offline.
 */
internal object SubscriptionMetadata {

    fun isLikelyMetadataName(name: String): Boolean {
        val normalized = name.lowercase().replace(" ", "")
        return METADATA_MARKERS.any(normalized::contains)
    }

    private val METADATA_MARKERS = listOf(
        "套餐到期",
        "到期时间",
        "剩余流量",
        "流量剩余",
        "更新订阅",
        "订阅更新",
        "出现问题",
        "官网地址",
        "官方网站",
        "重置订阅",
        "trafficleft",
        "remainingtraffic",
        "traffic:",
        "traffic：",
        "expiredate",
        "expirationdate",
        "expire:",
        "expire：",
        "updatesubscription",
    )
}
