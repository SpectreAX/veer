# Per-app transparent proxy on macOS: feasibility (Phase 2, research only, 2026-11-20)

Question: can Veer send only chosen apps' TCP and UDP to its Mihomo, without the system proxy and
without TUN, using a Network Extension? This is a report, not an implementation. Nothing here was
built or run; statements about Apple's APIs come from Apple's documentation and headers as known at
the time of writing and are marked where they need a hands-on check. Phase 1
([APP_ROUTING.md](APP_ROUTING.md)) is what ships today.

## Verdict

Feasible for a Developer ID build distributed on GitHub, with real work and two hard prerequisites:
a paid Apple Developer Program membership whose Developer ID provisioning includes the Network
Extension entitlement, and a user who approves a system extension. Recommended shape:

- a `NETransparentProxyProvider` **system extension**, configured with `NETransparentProxyManager`;
- per-app selection **inside the provider**, by each flow's `NEFlowMetaData.sourceAppSigningIdentifier`
  (and `sourceAppAuditToken` for the exact process), passing every other flow back to the system;
- chosen flows relayed to Mihomo's **local SOCKS5 inbound**, authenticated with a username that names
  the app, and routed by Mihomo's `IN-USER` rule, because Mihomo's PROCESS rules would only ever see
  the extension.

Estimated effort for a first usable version: 4–6 weeks for one developer, most of it in flow relaying
(UDP especially), lifecycle and failure handling, and testing across macOS versions.

## 1. APIs

| API | Role | Notes |
|---|---|---|
| `NETransparentProxyProvider` (macOS 11+) | Subclass of `NEAppProxyProvider`. Receives flows that match the manager's network rules; `handleNewFlow(_:)` returns `true` to take a flow or `false` to let the system send it as usual. | Unlike a per-app VPN, no MDM app rules are needed: the provider chooses per flow. |
| `NETransparentProxyManager` | Saves and starts the configuration (`loadAllFromPreferences`, `saveToPreferences`, `connection.startVPNTunnel()`). | The first save asks the user to allow the configuration. |
| `NETransparentProxyNetworkSettings` | `includedNetworkRules` / `excludedNetworkRules` of `NENetworkRule` (remote network or host, prefix, port, protocol, direction). | Coarse: by destination, not by app. Include outbound TCP and UDP to everything except loopback and the local ranges Veer keeps off TUN. |
| `NEAppProxyTCPFlow` | `open(withLocalEndpoint:)`, `readData`, `write`, `closeRead/Write`. | `remoteEndpoint`, and `remoteHostname` (macOS 11+) when the app connected by name (URLSession, Network.framework); otherwise only an IP. |
| `NEAppProxyUDPFlow` | `readDatagrams` / `writeDatagrams` with an endpoint per datagram. | Needs SOCKS5 UDP ASSOCIATE (or Mihomo's own UDP-capable inbound) on the other side. |
| `NEFlowMetaData` | `sourceAppSigningIdentifier`, `sourceAppUniqueIdentifier`, `sourceAppAuditToken` (10.15+), `filterFlowIdentifier`. | The audit token gives the pid and code identity of the process that owns the socket. Needs a hands-on check: what these report for flows created by XPC helpers and system daemons on behalf of an app. |
| System Extensions (`OSSystemExtensionRequest`) | Installs the extension from the app in `/Applications`. | User approval in System Settings (General → Login Items & Extensions, Network Extensions). |

`NEAppProxyProvider` with `NEAppRule` (per-app VPN) is configured by MDM on macOS. It is not a way
for a consumer app to pick apps, and it does not get around MDM; on a managed Mac, MDM can block or
require system extensions and Network Extension configurations, and Veer must respect that.

## 2. Keeping the source app's identity

If the provider simply opens its own connections to Mihomo, Mihomo sees every connection as coming
from the Veer extension, and PROCESS rules become useless. Options:

1. **SOCKS5 username per app (recommended).** Mihomo's SOCKS/mixed inbound supports username and
   password authentication (`authentication` / listener `users`), and the `IN-USER` rule matches the
   username. The provider authenticates as, for example, `app:com.google.Chrome`, and Veer writes
   `IN-USER,app:com.google.Chrome,<target>` rules (plus app-plus-domain `AND` rules) in place of
   Phase 1's PROCESS rules. Identity survives, the Connections page can show it, and Mihomo needs no
   change. Needs a check: whether `/connections` reports the inbound user for display.
2. **One listener per app (`IN-NAME`).** Works, but a listener per app does not scale and each needs
   a port.
3. **Do the routing decision in the provider.** Duplicates Mihomo's rule engine; rejected.

The provider uses the signing identifier for app grouping (all of Chrome's helpers share a team and a
prefix of its identifier) and the audit token to recognise its own and Mihomo's flows.

## 3. What has to work

| Topic | Approach | Risk |
|---|---|---|
| TCP | Relay `NEAppProxyTCPFlow` ⇄ SOCKS5 CONNECT to `127.0.0.1:<port>`, by hostname when `remoteHostname` is set, else IP. | Medium: back-pressure and half-close handling. |
| UDP | `NEAppProxyUDPFlow` ⇄ SOCKS5 UDP ASSOCIATE, one association per flow. | High: datagram framing, timeouts, many short flows (DNS). |
| IPv4 and IPv6 | Both through SOCKS5 address types. | Low. |
| DNS | Apps resolve through `mDNSResponder`, a shared daemon, so DNS queries are not attributable to apps; leave them alone. Domain rules then rely on `remoteHostname`, or Mihomo's sniffer (TLS SNI, HTTP Host) for IP-only flows. | Medium: IP-only flows to domain rules. No fake-IP (that needs owning DNS). |
| QUIC / HTTP/3 | UDP 443 relayed like other UDP; or rejected for chosen apps so browsers fall back to TCP (as Veer's "Disable QUIC"). | Medium. |
| Helpers and shared system processes | Chromium and Electron helpers carry the app's signing prefix and are grouped. WebKit networking, `nsurlsessiond`, `trustd`, etc. act for many apps; their flows are passed through, as Phase 1 does. | Needs a check: whether the metadata attributes a WebKit flow to Safari or to the WebKit process. |
| Loop protection | Never take flows from the extension itself or from Mihomo (by audit token pid or signing identifier); exclude loopback in network rules; Mihomo's outbound sockets must also be passed through. | High if wrong: a loop takes the Mac offline. |
| Mihomo crashes | The provider sees connect failures to the local port: fail open (return `false` for new flows, close relayed ones so apps retry directly) or fail closed (close flows), a user setting, default open. Veer restarts the core. | Medium. |
| Extension crashes | The system restarts it; flows it held are lost; while it is stopped, traffic is not intercepted (fail open by nature). | Needs a check on recent macOS. |
| Sleep and wake, network changes | `sleep(completionHandler:)` / `wake()`; drop relays on interface change; Mihomo's own reconnection. | Medium. |
| Other VPNs and proxies | A transparent proxy can run beside a packet-tunnel VPN; with several transparent proxies or content filters the order is the system's. The user's FlClash system proxy: apps that honour it connect to `127.0.0.1:7890`, which is loopback and excluded, so they keep going to FlClash. | Needs a check with a real VPN client. |
| Performance | Every relayed byte crosses the extension process and a local socket twice. | Medium for bulk downloads; measure. |

## 4. Distribution through GitHub releases

- **Membership and identity.** Network Extension entitlements require the paid Apple Developer
  Program. The extension and app need `com.apple.developer.networking.networkextension` with
  `app-proxy-provider-systemextension` (the Developer ID form of the value), and the app needs
  `com.apple.developer.system-extension.install`.
- **Provisioning.** These are restricted entitlements: both targets need Developer ID provisioning
  profiles that include them, embedded in the bundles. Veer's release build is signed with an Apple
  Development certificate today; that is not enough to ship this.
- **Signing and notarization.** Developer ID Application certificate, hardened runtime, secure
  timestamp, notarization and stapling of the DMG; `build-app.sh` already switches to these flags for
  a Developer ID identity.
- **Install.** The app must run from `/Applications` to install a system extension; the user approves
  it once, then approves the proxy configuration. Updates through Sparkle replace the app; the
  extension is replaced by an activation request with the new version (the delegate's
  `actionForReplacingExtension`).
- **Deployment target.** `NETransparentProxyProvider` is macOS 11+; Veer's minimum is macOS 14, so no
  extra availability gating beyond what the APIs above need.
- **Uninstall.** Removing the app should deactivate the extension (`OSSystemExtensionRequest.deactivationRequest`)
  and remove the configuration.

## 5. Plan if the user goes ahead

1. Spike (1 week): a signed system extension that passes everything through and logs
   `NEFlowMetaData` for Chrome, an Electron app, Safari, `curl`: answers the attribution questions.
2. TCP relay to Mihomo with `IN-USER` (1–2 weeks), the Phase 1 UI targeting `IN-USER` rules instead
   of PROCESS rules when the extension is on.
3. UDP, QUIC, failure modes, sleep/wake (1–2 weeks).
4. Distribution: Developer ID provisioning, notarized DMG, install and uninstall flows (1 week).

Phase 1 stays as the fallback when the extension is not installed or not allowed.
