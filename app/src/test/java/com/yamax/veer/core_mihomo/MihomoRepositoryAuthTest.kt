package com.yamax.veer.core_mihomo

import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.net.InetSocketAddress

class MihomoRepositoryAuthTest {
    @Test
    fun `version and readiness probes send bearer credential`() = runBlocking {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/version") { exchange ->
            val authorized = exchange.requestHeaders.getFirst("Authorization") == "Bearer test-secret"
            val body = if (authorized) "version-ok" else "unauthorized"
            val bytes = body.toByteArray()
            exchange.sendResponseHeaders(if (authorized) 200 else 401, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        }
        server.start()
        try {
            val repository = MihomoRepository(
                controllerPort = server.address.port,
                secret = "test-secret",
            )
            assertEquals("version-ok", repository.version())
            assertEquals(true, repository.controllerReady())
        } finally {
            server.stop(0)
        }
    }

    @Test
    fun `empty credential cannot construct a controller client`() {
        assertThrows(IllegalArgumentException::class.java) {
            MihomoRepository(controllerPort = 1, secret = "")
        }
    }
}
