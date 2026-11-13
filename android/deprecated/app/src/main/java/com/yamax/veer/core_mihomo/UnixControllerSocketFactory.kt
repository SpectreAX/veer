package com.yamax.veer.core_mihomo

import android.net.LocalSocket
import android.net.LocalSocketAddress
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.net.SocketException
import javax.net.SocketFactory

/** Lets OkHttp speak ordinary HTTP over Mihomo's app-private Unix socket. */
internal class UnixControllerSocketFactory(private val socketPath: String) : SocketFactory() {
    override fun createSocket(): Socket = UnixControllerSocket(socketPath)

    override fun createSocket(host: String, port: Int): Socket =
        createSocket().apply { connect(InetSocketAddress(host, port)) }

    override fun createSocket(host: String, port: Int, localHost: InetAddress, localPort: Int): Socket =
        createSocket(host, port)

    override fun createSocket(host: InetAddress, port: Int): Socket =
        createSocket().apply { connect(InetSocketAddress(host, port)) }

    override fun createSocket(
        address: InetAddress,
        port: Int,
        localAddress: InetAddress,
        localPort: Int,
    ): Socket = createSocket(address, port)
}

private class UnixControllerSocket(private val socketPath: String) : Socket() {
    private var local: LocalSocket? = null
    private var closed = false
    private var readTimeoutMs = 0

    override fun connect(endpoint: SocketAddress?) = connect(endpoint, 0)

    override fun connect(endpoint: SocketAddress?, timeout: Int) {
        if (closed) throw SocketException("Controller socket is closed")
        if (local != null) throw SocketException("Controller socket is already connected")
        val socket = LocalSocket()
        try {
            socket.connect(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
            socket.soTimeout = readTimeoutMs
            local = socket
        } catch (error: Exception) {
            socket.close()
            throw error
        }
    }

    override fun getInputStream(): InputStream =
        local?.inputStream ?: throw SocketException("Controller socket is not connected")

    override fun getOutputStream(): OutputStream =
        local?.outputStream ?: throw SocketException("Controller socket is not connected")

    override fun setSoTimeout(timeout: Int) {
        readTimeoutMs = timeout
        local?.soTimeout = timeout
    }

    override fun getSoTimeout(): Int = readTimeoutMs

    override fun setTcpNoDelay(on: Boolean) = Unit

    override fun getTcpNoDelay(): Boolean = true

    override fun setKeepAlive(on: Boolean) = Unit

    override fun getKeepAlive(): Boolean = false

    override fun shutdownInput() {
        local?.shutdownInput() ?: throw SocketException("Controller socket is not connected")
    }

    override fun shutdownOutput() {
        local?.shutdownOutput() ?: throw SocketException("Controller socket is not connected")
    }

    override fun isConnected(): Boolean = local != null && !closed

    override fun isClosed(): Boolean = closed

    override fun close() {
        if (!closed) {
            closed = true
            local?.close()
            local = null
        }
    }
}
