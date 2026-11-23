package mobile

import (
	"context"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/vless"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
)

const chainRecentTraffic = time.Minute

type chainActivity struct {
	active      int
	lastUsed    time.Time
	lastChecked time.Time
}

type chainHealth struct {
	mu         sync.Mutex
	tags       map[string]*chainActivity
	current    string
	failures   int
	generation uint64
}

func newChainHealth(outbounds []any) *chainHealth {
	h := &chainHealth{tags: make(map[string]*chainActivity)}
	for _, raw := range outbounds {
		out := raw.(map[string]any)
		stream, _ := out["streamSettings"].(map[string]any)
		socket, _ := stream["sockopt"].(map[string]any)
		if upstream, _ := socket["dialerProxy"].(string); upstream != "" {
			h.tags[out["tag"].(string)] = new(chainActivity)
		}
	}
	return h
}

func (h *chainHealth) use(tag string) func() {
	activity := h.tags[tag]
	if activity == nil {
		return nil
	}
	h.mu.Lock()
	generation := h.generation
	activity.active++
	activity.lastUsed = time.Now()
	h.mu.Unlock()
	return func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		if generation == h.generation {
			activity.active--
			activity.lastUsed = time.Now()
		}
	}
}

func (h *chainHealth) restart() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.generation++
	for _, activity := range h.tags {
		activity.active = 0
	}
	h.failures = 0
}

func (h *chainHealth) next() string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.current != "" {
		return h.current
	}
	var chosen string
	var lastChecked time.Time
	now := time.Now()
	for tag, activity := range h.tags {
		if (activity.active > 0 || now.Sub(activity.lastUsed) < chainRecentTraffic) &&
			(chosen == "" || activity.lastChecked.Before(lastChecked)) {
			chosen, lastChecked = tag, activity.lastChecked
		}
	}
	return chosen
}

func (h *chainHealth) result(tag string, reachable bool) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.tags[tag].lastChecked = time.Now()
	if reachable {
		h.current, h.failures = "", 0
		return "healthy"
	}
	h.current = tag
	h.failures++
	if h.failures >= 2 {
		return "restart"
	}
	return "failed"
}

// CheckChains performs an end-to-end check using the active chained outbound.
// It only checks routes used by real tunnel traffic and never falls back to direct.
func (s *VPNSession) CheckChains() string {
	return s.checkChains(5*time.Second, vless.ProbeURL, "https://www.cloudflare.com/cdn-cgi/trace")
}

func (s *VPNSession) checkChains(timeout time.Duration, destinations ...string) string {
	if s.health == nil || s.ctx.Err() != nil {
		return "idle"
	}
	tag := s.health.next()
	if tag == "" {
		return "idle"
	}
	for _, destination := range destinations {
		ctx, cancel := context.WithTimeout(s.ctx, timeout)
		reachable := probeChain(ctx, s.instance, tag, destination)
		cancel()
		if s.ctx.Err() != nil {
			return "idle"
		}
		if reachable {
			return s.health.result(tag, true)
		}
	}
	return s.health.result(tag, false)
}

func probeChain(ctx context.Context, active *core.Instance, tag, endpoint string) bool {
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + address)
			if err != nil {
				return nil, err
			}
			return core.Dial(session.SetForcedOutboundTagToContext(ctx, tag), active, dest)
		},
	}
	defer transport.CloseIdleConnections()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return false
	}
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	_ = response.Body.Close()
	// Any authenticated HTTPS response proves the chain transported traffic.
	return true
}
