package com.yamax.veer.core_logging

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VeerLogRedactionTest {
    @Test
    fun `redacts api keys bearer values credentials and urls`() {
        val secret = "sk-" + "a".repeat(32)
        val output = VeerLog.redact(
            "Authorization: Bearer abc.def password=hunter2 " +
                "key=my-secret $secret https://example.com/sub/private?token=value",
        )

        assertFalse(output.contains("abc.def"))
        assertFalse(output.contains("hunter2"))
        assertFalse(output.contains("my-secret"))
        assertFalse(output.contains(secret))
        assertFalse(output.contains("example.com"))
        assertTrue(output.contains("[redacted"))
    }

    @Test
    fun `keeps ordinary diagnostic text`() {
        val input = "proxy exit failed 1/2; controller available"

        assertTrue(VeerLog.redact(input) == input)
    }
}
