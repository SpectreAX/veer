package com.yamax.veer.core_profile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DnsOverridePolicyTest {
    @Test
    fun `accepts numeric DNS DoH DoT and transport endpoints`() {
        val policy = DnsOverridePolicy(
            mode = DnsOverrideMode.CUSTOM,
            defaultNameservers = listOf("1.1.1.1", "2001:4860:4860::8888"),
            nameservers = listOf(
                "https://dns.example/dns-query",
                "tls://dns.example:853",
                "tcp://1.1.1.1:53",
                "udp://8.8.8.8",
                "quic://dns.example:853",
            ),
        )

        assertTrue(DnsOverrideValidator.validate(policy).isEmpty())
    }

    @Test
    fun `rejects dependency loops credentials invalid ports and unknown protocols`() {
        val policy = DnsOverridePolicy(
            mode = DnsOverrideMode.CUSTOM,
            defaultNameservers = listOf("bootstrap.example"),
            nameservers = listOf(
                "https://user:secret@dns.example/dns-query",
                "https://dns.example",
                "tls://dns.example:0",
                "ftp://dns.example/query",
            ),
        )

        val problems = DnsOverrideValidator.validate(policy).map { it.problem }

        assertEquals(5, problems.size)
        assertTrue(DnsValidationProblem.BOOTSTRAP_IP_ONLY in problems)
        assertTrue(DnsValidationProblem.CREDENTIALS_NOT_ALLOWED in problems)
        assertTrue(DnsValidationProblem.DOH_PATH_REQUIRED in problems)
        assertTrue(DnsValidationProblem.INVALID_PORT in problems)
        assertTrue(DnsValidationProblem.UNSUPPORTED_SCHEME in problems)
    }

    @Test
    fun `normalization removes blanks duplicates and clears inherited fields`() {
        val custom = DnsOverridePolicy(
            mode = DnsOverrideMode.CUSTOM,
            defaultNameservers = listOf(" 1.1.1.1 ", "", "1.1.1.1"),
            nameservers = listOf(" https://dns.example/dns-query "),
        ).normalized()

        assertEquals(listOf("1.1.1.1"), custom.defaultNameservers)
        assertEquals(listOf("https://dns.example/dns-query"), custom.nameservers)
        assertEquals(
            DnsOverridePolicy(),
            custom.copy(mode = DnsOverrideMode.INHERIT).normalized(),
        )
    }
}
