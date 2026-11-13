package com.yamax.veer.core_mihomo

import com.sun.net.httpserver.HttpServer
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger

class MihomoLocalProxyTest {
    @Test
    fun `proxy client answers an authentication challenge`() {
        val authorized = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/") { exchange ->
            val valid = exchange.requestHeaders.getFirst("Proxy-Authorization") ==
                Credentials.basic("veer", "test-secret")
            if (valid) authorized.incrementAndGet()
            else exchange.responseHeaders.add("Proxy-Authenticate", "Basic realm=veer")
            val body = if (valid) "ok" else "auth required"
            val bytes = body.toByteArray()
            exchange.sendResponseHeaders(if (valid) 200 else 407, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            val client = MihomoLocalProxy.configure(
                OkHttpClient.Builder(), "test-secret", server.address.port,
            ).build()
            client.newCall(Request.Builder().url("http://example.invalid/").build())
                .execute().use { response ->
                    assertEquals(200, response.code)
                    assertEquals("ok", response.body?.string())
                }
            assertEquals(1, authorized.get())
        } finally {
            server.stop(0)
        }
    }
}
