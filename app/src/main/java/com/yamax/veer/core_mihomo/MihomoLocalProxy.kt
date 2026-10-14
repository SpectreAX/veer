package com.yamax.veer.core_mihomo

import okhttp3.Credentials
import okhttp3.OkHttpClient
import java.net.InetSocketAddress
import java.net.Proxy

/** Authenticated access to Veer's loopback mixed-port. */
internal object MihomoLocalProxy {
    fun clientBuilder(): OkHttpClient.Builder =
        configure(OkHttpClient.Builder(), ControllerSecretStore.getOrCreate())

    internal fun configure(
        builder: OkHttpClient.Builder,
        secret: String,
        port: Int = 7890,
    ): OkHttpClient.Builder {
        require(secret.isNotBlank()) { "Local proxy credential is required" }
        val header = Credentials.basic("veer", secret)
        return builder
            .proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port)))
            .proxyAuthenticator { _, response ->
                if (response.request.header("Proxy-Authorization") != null) null
                else response.request.newBuilder()
                    .header("Proxy-Authorization", header)
                    .build()
            }
    }
}
