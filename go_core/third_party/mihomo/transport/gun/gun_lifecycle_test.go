package gun

import (
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
