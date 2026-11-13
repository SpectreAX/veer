package com.yamax.veer.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AiHistoryStoreTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun `history survives a new store instance and marks an undo once`() {
        val file = temporaryFolder.newFile("history.json")
        val first = AiHistoryStore.forFile(file)
        val mutation = AiHistoryMutation(
            rulesBefore = AiHistoryRuleStore(emptyList(), emptyList()),
            rulesAfter = AiHistoryRuleStore(
                enabled = listOf("GEOSITE,openai,US"),
                disabled = emptyList(),
            ),
        )
        val entry = first.append(
            profileId = "profile-a",
            prompt = "ChatGPT go US",
            source = AiHistorySource.LOCAL,
            status = AiHistoryStatus.SUCCESS,
            summary = "done",
            generatedRules = listOf("GEOSITE,openai,US"),
            mutation = mutation,
            timestampMs = 123L,
            id = "entry-1",
        )

        assertTrue(entry.canUndo)
        val reopened = AiHistoryStore.forFile(file)
        assertEquals(entry, reopened.entries().single())
        assertTrue(reopened.markUndone("entry-1", timestampMs = 456L))
        assertFalse(reopened.markUndone("entry-1", timestampMs = 789L))
        assertEquals(456L, reopened.entries().single().undoneAtMs)
        assertFalse(reopened.entries().single().canUndo)
    }

    @Test
    fun `history is newest first and bounded to one hundred entries`() {
        val store = AiHistoryStore.forFile(temporaryFolder.newFile("bounded.json"))
        repeat(105) { index ->
            store.append(
                profileId = "profile-a",
                prompt = "command-$index",
                source = AiHistorySource.SYSTEM,
                status = AiHistoryStatus.FAILURE,
                summary = "failure-$index",
                timestampMs = index.toLong(),
                id = "id-$index",
            )
        }

        val entries = store.entries()
        assertEquals(100, entries.size)
        assertEquals("command-104", entries.first().prompt)
        assertEquals("command-5", entries.last().prompt)
    }

    @Test
    fun `undo precondition detects later rule and selector changes`() {
        val before = AiHistoryRuleStore(emptyList(), emptyList())
        val after = AiHistoryRuleStore(listOf("GEOSITE,netflix,JP"), emptyList())
        val mutation = AiHistoryMutation(
            rulesBefore = before,
            rulesAfter = after,
            selectors = listOf(AiHistorySelectorChange("PROXY", "HK", "US")),
        )

        assertNull(mutation.stateConflict(after, mapOf("PROXY" to "US")))
        assertEquals(
            "AI 规则已被后续操作修改",
            mutation.stateConflict(before, mapOf("PROXY" to "US")),
        )
        assertEquals(
            "策略组 PROXY 已被后续操作修改",
            mutation.stateConflict(after, mapOf("PROXY" to "JP")),
        )
    }
}
