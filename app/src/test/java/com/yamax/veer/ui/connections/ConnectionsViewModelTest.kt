package com.yamax.veer.ui.connections

import com.yamax.veer.core_mihomo.MihomoRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ConnectionsViewModelTest {
    private val dispatcher: TestDispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun `search matches host rule payload address and proxy chain`() {
        val connections = listOf(
            connection(
                id = "host",
                host = "netflix.com",
                rule = "DOMAIN-SUFFIX",
                payload = "netflix.com",
                chains = listOf("日本节点"),
            ),
            connection(
                id = "address",
                destinationIp = "203.0.113.8",
                rule = "MATCH",
                chains = listOf("香港节点"),
            ),
        )

        assertEquals(
            listOf("host"),
            filterAndSortConnections(connections, "日本", SortMode.HOST_ASC).map { it.id },
        )
        assertEquals(
            listOf("address"),
            filterAndSortConnections(connections, "203.0.113", SortMode.HOST_ASC).map { it.id },
        )
        assertEquals(
            listOf("host"),
            filterAndSortConnections(connections, "NETFLIX", SortMode.HOST_ASC).map { it.id },
        )
    }

    @Test
    fun `sort modes order traffic duration and host predictably`() {
        val connections = listOf(
            connection(
                id = "newer",
                host = "z.example",
                upload = 80,
                download = 20,
                start = "2026-07-31T12:00:00Z",
            ),
            connection(
                id = "older",
                host = "A.example",
                upload = 1,
                download = 2,
                start = "2026-07-31T10:00:00Z",
            ),
            connection(
                id = "unknown",
                destinationIp = "198.51.100.5",
                upload = 10,
                download = 20,
                start = "",
            ),
        )

        assertEquals(
            listOf("newer", "unknown", "older"),
            filterAndSortConnections(connections, "", SortMode.TRAFFIC_DESC).map { it.id },
        )
        assertEquals(
            listOf("older", "newer", "unknown"),
            filterAndSortConnections(connections, "", SortMode.DURATION_DESC).map { it.id },
        )
        assertEquals(
            listOf("unknown", "older", "newer"),
            filterAndSortConnections(connections, "", SortMode.HOST_ASC).map { it.id },
        )
    }

    @Test
    fun `successful close removes connection without waiting for next poll`() = runTest(dispatcher) {
        val gateway = FakeConnectionsGateway(
            connections = mutableListOf(
                connection(id = "one", host = "one.example"),
                connection(id = "two", host = "two.example"),
            ),
        )
        val viewModel = ConnectionsViewModel(
            gateway = gateway,
            runningFlow = MutableStateFlow(true),
        )
        advanceUntilIdle()

        viewModel.refresh()
        advanceUntilIdle()
        viewModel.closeConnection("one")
        advanceUntilIdle()

        assertEquals(listOf("one"), gateway.closedIds)
        assertEquals(listOf("two"), viewModel.uiState.value.connections.map { it.id })
    }

    @Test
    fun `load failure is distinct from an empty connection list`() = runTest(dispatcher) {
        val gateway = FakeConnectionsGateway(
            connections = mutableListOf(connection(id = "existing", host = "keep.example")),
        )
        val viewModel = ConnectionsViewModel(
            gateway = gateway,
            runningFlow = MutableStateFlow(true),
        )
        advanceUntilIdle()
        viewModel.refresh()
        advanceUntilIdle()
        gateway.loadFailure = true

        viewModel.refresh()
        advanceUntilIdle()

        assertEquals(listOf("existing"), viewModel.uiState.value.connections.map { it.id })
        assertFalse(viewModel.uiState.value.loading)
        assertTrue(viewModel.uiState.value.message.orEmpty().contains("刷新连接失败"))
    }

    private class FakeConnectionsGateway(
        val connections: MutableList<MihomoRepository.ConnectionInfo>,
    ) : ConnectionsGateway {
        val closedIds = mutableListOf<String>()
        var loadFailure = false

        override suspend fun loadConnections(): Result<List<MihomoRepository.ConnectionInfo>> =
            if (loadFailure) {
                Result.failure(IllegalStateException("controller unavailable"))
            } else {
                Result.success(connections.toList())
            }

        override suspend fun closeConnection(id: String): Boolean {
            closedIds += id
            connections.removeAll { it.id == id }
            return true
        }

        override suspend fun closeAllConnections(): Boolean {
            connections.clear()
            return true
        }
    }

    private fun connection(
        id: String,
        host: String = "",
        destinationIp: String = "",
        rule: String = "",
        payload: String = "",
        chains: List<String> = emptyList(),
        upload: Long = 0,
        download: Long = 0,
        start: String = "",
    ) = MihomoRepository.ConnectionInfo(
        id = id,
        host = host,
        destinationIP = destinationIp,
        network = "tcp",
        type = "HTTP",
        chains = chains,
        rule = rule,
        rulePayload = payload,
        download = download,
        upload = upload,
        start = start,
    )
}
