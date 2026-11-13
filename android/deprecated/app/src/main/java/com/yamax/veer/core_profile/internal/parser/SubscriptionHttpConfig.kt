package com.yamax.veer.core_profile.internal.parser

internal object SubscriptionHttpConfig {

    /**
     * UA pool tried in order. Primary = ClashMetaForAndroid; okhttp is the last-resort fallback.
     * Many providers allow-list known Clash ecosystem clients and block generic JVM UAs.
     */
    val userAgents: List<String> = listOf(
        "clash.meta",
        "FlClash/0.8.72",
        "Clash-verge/1.7.7",
        "okhttp/4.12.0",
    )

    /**
     * Headers sent on every subscription request.
     *
     * Accept-Encoding is intentionally absent — the BrotliInterceptor appends `br` and
     * OkHttp appends `gzip,deflate`, so both compression schemes are negotiated automatically
     * and the response is transparently decompressed before we read the body.
     *
     * Sec-Fetch-* are browser-style hints; some CDN edge configs require them to pass
     * bot filters even when the UA is a known Clash client.
     */
    val additionalHeaders: Map<String, String> = mapOf(
        "Accept"          to "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language" to "zh-CN,zh;q=0.9,en;q=0.8",
        "Cache-Control"   to "no-cache",
        "Pragma"          to "no-cache",
        "Sec-Fetch-Site"  to "none",
        "Sec-Fetch-Mode"  to "no-cors",
        "Sec-Fetch-Dest"  to "empty",
        "Connection"      to "keep-alive",
    )

    const val CONNECT_TIMEOUT_S = 15L
    const val READ_TIMEOUT_S    = 30L

    /** HTTP status codes that suggest UA rejection and should trigger a UA rotation retry. */
    val retryStatusCodes: Set<Int> = setOf(400, 403)

    /** Body must contain at least one of these strings to be considered a Clash YAML subscription. */
    val clashYamlKeywords: List<String> = listOf(
        "proxies:",
        "proxy-groups:",
        "mixed-port",
        "rules:",
    )
}
