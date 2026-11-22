import Foundation
import Testing
@testable import VeerApp

@MainActor struct CoreStartNetworkNoticeTests {
    @Test func theNoticeReflectsWhatStartingCanEnable() {
        let store = SnapshotRunner.sample()
        #expect(store.coreStartNetworkNotice == nil)

        store.systemProxyRemembered = true
        #expect(store.coreStartNetworkNotice == String(localized: "启动后将打开系统代理。"))

        store.settings.tun = true
        #expect(store.coreStartNetworkNotice == String(localized: "启动时会打开系统代理，并尝试用 TUN 接管流量。"))

        store.systemProxyRemembered = false
        #expect(store.coreStartNetworkNotice == String(localized: "启动时会尝试用 TUN 接管流量。若失败，将打开系统代理。"))
    }

    @Test func thereIsNoStartNoticeWithoutAProfile() {
        let store = SnapshotRunner.sample(profiles: false)
        store.systemProxyRemembered = true
        store.settings.tun = true
        #expect(store.coreStartNetworkNotice == nil)
    }
}
