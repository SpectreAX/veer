package dialer

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

func TestParallelDialIPsCancelsLosingRacers(t *testing.T) {
	t.Parallel()

	winner := netip.MustParseAddr("192.0.2.1")
	ips := []netip.Addr{
		winner,
		netip.MustParseAddr("192.0.2.2"),
		netip.MustParseAddr("192.0.2.3"),
	}
	var cancelled atomic.Int32

	conn, err := parallelDialIPs(
		context.Background(),
		ips,
		func(ctx context.Context, ip netip.Addr) (net.Conn, error) {
			if ip == winner {
				client, peer := net.Pipe()
				_ = peer.Close()
				return client, nil
			}
			<-ctx.Done()
			cancelled.Add(1)
			return nil, ctx.Err()
		},
	)
	if err != nil {
		t.Fatalf("parallelDialIPs returned error: %v", err)
	}
	defer conn.Close()

	deadline := time.Now().Add(time.Second)
	for cancelled.Load() != int32(len(ips)-1) && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got, want := cancelled.Load(), int32(len(ips)-1); got != want {
		t.Fatalf("losing racers cancelled=%d, want %d", got, want)
	}
}

func TestParallelDialIPsPreservesAllErrors(t *testing.T) {
	t.Parallel()

	first := errors.New("first")
	second := errors.New("second")
	_, err := parallelDialIPs(
		context.Background(),
		[]netip.Addr{
			netip.MustParseAddr("192.0.2.1"),
			netip.MustParseAddr("192.0.2.2"),
		},
		func(_ context.Context, ip netip.Addr) (net.Conn, error) {
			if ip == netip.MustParseAddr("192.0.2.1") {
				return nil, first
			}
			return nil, second
		},
	)
	if !errors.Is(err, first) || !errors.Is(err, second) {
		t.Fatalf("joined error %v does not preserve both failures", err)
	}
}
