package mobile

import (
	"context"
	"testing"
	"time"
)

func TestChainHealthTracksOnlyActiveChainsAndPreservesRetryAcrossRestart(t *testing.T) {
	out := func(tag string, conn string) any {
		return map[string]any{"tag": tag, "streamSettings": map[string]any{"sockopt": map[string]any{"dialerProxy": conn}}}
	}
	health := newChainHealth([]any{out("first", "vless"), out("second", "vless"), out("direct", "")})
	if health.next() != "" || health.use("direct") != nil {
		t.Fatal("idle VPN and direct traffic should not start checks")
	}
	finish := health.use("first")
	if got := health.next(); got != "first" {
		t.Fatalf("active chain = %q", got)
	}
	if health.result("first", false) != "failed" || health.result("first", true) != "healthy" ||
		health.result("first", false) != "failed" {
		t.Fatal("a successful check must reset the failure streak")
	}
	finishSecond := health.use("second")
	defer finishSecond()
	if health.next() != "first" || health.result("first", false) != "restart" {
		t.Fatal("a second consecutive failure must apply to the same chain")
	}
	health.restart()
	finish()
	if health.tags["first"].active != 0 || health.next() != "first" {
		t.Fatal("restart must retain the affected chain without counting the old flow")
	}
	if health.result("first", false) != "failed" || health.result("first", true) != "healthy" ||
		health.next() != "second" {
		t.Fatal("recovery must reset the failure streak and continue checking other routes")
	}
}

func TestChainHealthSkipsExpiredTrafficAndCancelledSession(t *testing.T) {
	health := &chainHealth{tags: map[string]*chainActivity{
		"old": {lastUsed: time.Now().Add(-2 * chainRecentTraffic)},
	}}
	if health.next() != "" {
		t.Fatal("expired traffic must not trigger checks")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	session := &VPNSession{ctx: ctx, health: health}
	if got := session.CheckChains(); got != "idle" {
		t.Fatalf("cancelled session returned %q", got)
	}
}
