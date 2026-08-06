package gun

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
)

func TestClientClosePreventsLateTransportCreation(t *testing.T) {
	var makerCalls atomic.Int32
	client := NewClient(
		func() *Transport {
			makerCalls.Add(1)
			return &Transport{}
		},
		1,
		0,
		0,
	)

	if err := client.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	if _, err := client.Dial(); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("Dial() after Close() error = %v, want net.ErrClosed", err)
	}
	if got := makerCalls.Load(); got != 0 {
		t.Fatalf("transport maker called %d times after Close(), want 0", got)
	}
}

func TestCloseAllTransportsClosesRegisteredTransports(t *testing.T) {
	first := NewTransport(
		func(context.Context, string, string) (net.Conn, error) {
			return nil, errors.New("not used")
		},
		nil,
		&Config{},
	)
	second := NewTransport(
		func(context.Context, string, string) (net.Conn, error) {
			return nil, errors.New("not used")
		},
		nil,
		&Config{},
	)

	CloseAllTransports()

	for index, transport := range []*Transport{first, second} {
		select {
		case <-transport.ctx.Done():
		default:
			t.Fatalf("transport %d context remains active", index)
		}
	}
	var remaining int
	liveTransports.Range(func(_, _ any) bool {
		remaining++
		return true
	})
	if remaining != 0 {
		t.Fatalf("live transport registry contains %d entries", remaining)
	}
}

func TestTransportCloseClosesTrackedRawConnection(t *testing.T) {
	transport := NewTransport(
		func(context.Context, string, string) (net.Conn, error) {
			return nil, errors.New("not used")
		},
		nil,
		&Config{},
	)
	local, peer := net.Pipe()
	defer peer.Close()
	_, err := transport.trackConnection(local)
	if err != nil {
		t.Fatalf("trackConnection() error = %v", err)
	}

	if err := transport.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if _, err := peer.Write([]byte("probe")); err == nil {
		t.Fatal("peer write succeeded after transport closed its raw connection")
	}
	lateLocal, latePeer := net.Pipe()
	defer latePeer.Close()
	if _, err := transport.trackConnection(lateLocal); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("late trackConnection() error = %v, want net.ErrClosed", err)
	}
}
