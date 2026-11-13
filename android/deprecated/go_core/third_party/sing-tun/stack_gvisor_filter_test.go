//go:build with_gvisor

package tun

import (
	"testing"

	"github.com/metacubex/gvisor/pkg/tcpip/stack"
)

type attachRecorder struct {
	stack.LinkEndpoint
	dispatcher stack.NetworkDispatcher
}

func (r *attachRecorder) Attach(dispatcher stack.NetworkDispatcher) {
	r.dispatcher = dispatcher
}

func TestLinkEndpointFilterPreservesNilDetach(t *testing.T) {
	raw := &attachRecorder{}
	filter := &LinkEndpointFilter{LinkEndpoint: raw}

	filter.Attach(nil)

	if raw.dispatcher != nil {
		t.Fatal("Attach(nil) was wrapped; fd-backed endpoint would remain attached")
	}
}
