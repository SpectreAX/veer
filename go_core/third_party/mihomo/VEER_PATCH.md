# Veer lifecycle patch

This directory mirrors Mihomo v1.19.29, the version pinned by
`go_core/go.mod`. It exists because Veer embeds Mihomo in a long-lived
gomobile process instead of exiting after `executor.Shutdown()`.

Veer carries a small embedded-runtime lifecycle patch set:

- `adapter/provider/healthcheck.go` cancels in-flight checks at shutdown. On
  Android it does not make the VPN Stop watchdog inherit a complete batch of
  unreachable-node timeouts; other targets keep the strict join.
- `adapter/adapter.go` performs URL tests as synchronous one-connection
  HTTP/1.1 probes instead of creating a temporary pooled transport per probe.
- `component/dialer` cancels losing parallel dials and gives raw TCP dials a
  hard default timeout, including Android stacks that delay context wakeups.
- `dns/doh.go` tracks and permanently closes old resolver generations.
  Android uses request-scoped HTTP/1.1 connections so `persistConn` loops
  cannot accumulate across in-process VPN restarts. Connection registration
  now shares the close gate, so a dial completing after resolver shutdown is
  rejected instead of escaping the tracked set.
- `transport/gun/gun.go` treats `Close` as terminal. A closed gRPC-over-HTTP
  client returns `net.ErrClosed` instead of lazily creating a new transport
  after the owning provider generation has been destroyed.
- resolver and TUN shutdown paths expose synchronous cancellation/cleanup
  barriers used by `go_core/veer_core.go`.

These changes are covered by host unit tests and the physical-device
Start/Stop fault matrix. On HyperOS/Android 13, all 14 lifecycle cases pass and
repeated restart batches return to a stable goroutine count.

Remove the local `replace` and this mirror after an equivalent lifecycle fix
is available in the pinned upstream release.
