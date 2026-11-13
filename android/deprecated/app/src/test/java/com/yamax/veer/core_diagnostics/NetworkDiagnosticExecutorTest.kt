package com.yamax.veer.core_diagnostics

import com.yamax.veer.core_mihomo.MihomoRepository
import org.junit.Assert.assertEquals
import org.junit.Test

class NetworkDiagnosticExecutorTest {

    @Test
    fun `classifier reports the earliest failing network layer`() {
        val healthy = DiagnosticEvidence(
            physicalNetwork = true,
            vpnRunning = true,
            tunPresent = true,
            controllerReachable = true,
            dnsHealthy = true,
            ruleBlocked = false,
            proxyInternetHealthy = true,
            targetReachable = true,
        )

        assertEquals(DiagnosticCategory.HEALTHY, NetworkDiagnosisClassifier.classify(healthy))
        assertEquals(
            DiagnosticCategory.SYSTEM_NETWORK,
            NetworkDiagnosisClassifier.classify(healthy.copy(physicalNetwork = false)),
        )
        assertEquals(
            DiagnosticCategory.VPN_TUN,
            NetworkDiagnosisClassifier.classify(healthy.copy(tunPresent = false)),
        )
        assertEquals(
            DiagnosticCategory.CONTROLLER,
            NetworkDiagnosisClassifier.classify(healthy.copy(controllerReachable = false)),
        )
        assertEquals(
            DiagnosticCategory.DNS,
            NetworkDiagnosisClassifier.classify(healthy.copy(dnsHealthy = false)),
        )
        assertEquals(
            DiagnosticCategory.RULE,
            NetworkDiagnosisClassifier.classify(healthy.copy(ruleBlocked = true)),
        )
        assertEquals(
            DiagnosticCategory.PROXY_EXIT,
            NetworkDiagnosisClassifier.classify(healthy.copy(proxyInternetHealthy = false)),
        )
        assertEquals(
            DiagnosticCategory.TARGET_SITE,
            NetworkDiagnosisClassifier.classify(healthy.copy(targetReachable = false)),
        )
    }

    @Test
    fun `runtime rule matcher respects controller order and domain suffix`() {
        val rules = listOf(
            MihomoRepository.RuleState(0, "DomainSuffix", "example.com", "REJECT"),
            MihomoRepository.RuleState(1, "Match", "", "PROXY"),
        )

        val matched = NetworkDiagnosticExecutor.matchingRule(
            rules = rules,
            domain = "api.example.com",
            service = null,
        )

        assertEquals(0, matched?.index)
        assertEquals("REJECT", matched?.proxy)
    }

    @Test
    fun `runtime rule matcher maps service to geosite`() {
        val rules = listOf(
            MihomoRepository.RuleState(0, "GeoSite", "netflix", "JP"),
            MihomoRepository.RuleState(1, "Match", "", "PROXY"),
        )

        val matched = NetworkDiagnosticExecutor.matchingRule(
            rules = rules,
            domain = "www.netflix.com",
            service = "netflix",
        )

        assertEquals("JP", matched?.proxy)
    }
}
