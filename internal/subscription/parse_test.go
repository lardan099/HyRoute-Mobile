package subscription

import (
	"testing"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
)

// A subscription of thousands keeps its first maxSubServers, with a
// warning: each server is a profile merged and sealed on every update.
func TestSubscriptionServerCap(t *testing.T) {
	l := capServers(Links{Profiles: make([]hysteria.Profile, maxSubServers+5)})
	if len(l.Profiles) != maxSubServers || len(l.Warnings) != 1 {
		t.Fatalf("%d servers, %q", len(l.Profiles), l.Warnings)
	}
	if l := capServers(Links{Profiles: make([]hysteria.Profile, 3)}); len(l.Profiles) != 3 || len(l.Warnings) != 0 {
		t.Fatalf("%d servers, %q", len(l.Profiles), l.Warnings)
	}
}
