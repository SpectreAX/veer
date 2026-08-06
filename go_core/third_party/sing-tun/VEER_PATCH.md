# Veer sing-tun lifecycle patch

This directory is the exact `github.com/metacubex/sing-tun` `v0.4.21` source
used by Mihomo `v1.19.29`, plus one Android embedded-runtime lifecycle fix.

`LinkEndpointFilter.Attach` must forward `nil` unchanged. In gVisor,
`Attach(nil)` is the detach signal that stops fd-backed readers and their packet
processors. Upstream `v0.4.21` always wraps the argument, turning `nil` into a
non-nil `networkDispatcherFilter`; repeated in-process TUN restarts therefore
retain `BlockingPollUntilStopped` and packet-processor goroutines.

The fix is covered by `TestLinkEndpointFilterPreservesNilDetach` and by Veer's
physical-device repeated Start/Stop goroutine inventory. Remove the local
`replace` after an equivalent fix is available in the pinned upstream release.
