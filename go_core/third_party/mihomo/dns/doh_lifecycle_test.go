package dns

import (
	"context"
	"errors"
	"io"
	"net"
	"testing"
)

func TestCloseAllDoHClientsPreventsClientRecreation(t *testing.T) {
	doh := &dnsOverHTTPS{}
	liveDoHClients.Store(doh, struct{}{})

	CloseAllDoHClients()

	if _, loaded := liveDoHClients.Load(doh); loaded {
		t.Fatal("closed DoH client remained in the live registry")
	}
	if _, _, err := doh.getClient(context.Background()); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("getClient after permanent close returned %v, want net.ErrClosed", err)
	}
}

func TestClosedDoHRejectsLateConnectionRegistration(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()

	doh := &dnsOverHTTPS{closed: true}
	got, err := doh.trackConnection(client)
	if got != nil {
		t.Fatal("trackConnection() returned a connection for a closed resolver")
	}
	if !errors.Is(err, net.ErrClosed) {
		t.Fatalf("trackConnection() error = %v, want net.ErrClosed", err)
	}

	var one [1]byte
	if _, err := server.Read(one[:]); !errors.Is(err, io.EOF) {
		t.Fatalf("late connection peer read error = %v, want EOF", err)
	}
}
