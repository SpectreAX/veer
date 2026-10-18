package com.yamax.veer.core_mihomo

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProfileSelectionStoreTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun `choices are scoped to profile and invalid members are pruned`() {
        val home = temporaryFolder.newFolder("selections")
        ProfileSelectionStore.record(home, "profile-a", "PROXY", "A1")
        ProfileSelectionStore.record(home, "profile-b", "PROXY", "B1")
        assertEquals(mapOf("PROXY" to "A1"), ProfileSelectionStore.read(home, "profile-a"))
        assertEquals(mapOf("PROXY" to "B1"), ProfileSelectionStore.read(home, "profile-b"))

        val group = MihomoRepository.ProxyState(
            name = "PROXY", type = "Selector", now = "DIRECT",
            members = listOf("A2", "DIRECT"), delayMs = null,
        )
        val snapshot = MihomoRepository.RoutingSnapshot(mapOf("PROXY" to group))
        assertEquals(emptyMap<String, String>(),
            ProfileSelectionStore.validSelections(ProfileSelectionStore.read(home, "profile-a"), snapshot))
    }
}
