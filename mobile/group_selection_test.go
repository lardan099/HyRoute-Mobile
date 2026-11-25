package mobile

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
)

func TestMainServerGroupChoosesOnFirstFlow(t *testing.T) {
	for _, platform := range []string{"iOS", "Android"} {
		t.Run(platform, func(t *testing.T) {
			testCases := []struct {
				name  string
				group serverGroup
				want  string
			}{
				{"FastestPrimary", serverGroup{Primary: []string{"slow", "fast"}, Reserve: "reserve"}, "fast"},
				{"FailedFirstPrimary", serverGroup{Primary: []string{"failed", "slow"}}, "slow"},
				{"ReserveAfterFailure", serverGroup{Primary: []string{"failed"}, Reserve: "reserve"}, "reserve"},
			}
			for _, tc := range testCases {
				t.Run(tc.name, func(t *testing.T) {
					testMainServerGroupSelection(t, platform == "Android", tc.group, tc.want)
				})
			}
		})
	}
}

func testMainServerGroupSelection(t *testing.T, android bool, group serverGroup, want string) {
	t.Helper()
	var servers []hysteria.Profile
	addresses := make(map[string]string)
	for _, member := range []struct {
		id    string
		delay time.Duration
	}{{"slow", 180 * time.Millisecond}, {"fast", 80 * time.Millisecond}, {"reserve", 0}, {"failed", 0}} {
		endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/probe" {
				if member.id == "failed" {
					panic(http.ErrAbortHandler)
				}
				time.Sleep(member.delay)
				w.WriteHeader(http.StatusNoContent)
				return
			}
			_, _ = io.WriteString(w, member.id)
		}))
		t.Cleanup(endpoint.Close)
		addresses[member.id] = strings.TrimPrefix(endpoint.URL, "http://")
		servers = append(servers, hysteria.Profile{ID: member.id, Name: member.id, Host: "127.0.0.1", Ports: "443", Auth: "fixture"})
	}
	group.ID, group.Name = "group", "Group"
	state := clientState{
		Subscriptions: []savedSubscription{{Snapshot: importedSubscription{Servers: servers}}},
		Settings:      clientSettings{Selected: group.ID},
		ServerGroups:  []serverGroup{group},
	}
	plan, err := NewVPNPlan(encodeNetworkTestState(t, state), android)
	if err != nil {
		t.Fatal(err)
	}
	config, err := plan.configuration(t.Context(), false, vpnResolveForTest)
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range config.xray["outbounds"].([]any) {
		out := raw.(map[string]any)
		label := strings.TrimSuffix(config.labels[out["tag"].(string)], " (резерв)")
		if address := addresses[strings.TrimPrefix(label, "Group · ")]; address != "" {
			// Keep the production group tags and routing, with local outbounds
			// so the fixture controls the delay of each path independently.
			out["protocol"] = "freedom"
			out["settings"] = map[string]any{
				"redirect":   address,
				"finalRules": []any{map[string]any{"action": "allow", "ip": []string{"127.0.0.1/32"}}},
			}
			delete(out, "streamSettings")
		}
	}
	observation := config.xray["burstObservatory"].(map[string]any)
	observation["pingConfig"].(map[string]any)["destination"] = "http://127.0.0.1:1/probe"
	instance, err := config.start(t.Context(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = instance.Close() })
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + address)
			if err != nil {
				return nil, err
			}
			ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: "hyroute-tun"})
			return core.Dial(ctx, instance, dest)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	res, err := client.Get("http://127.0.0.1:1/traffic")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != want {
		t.Fatalf("first flow used %q, want %q", body, want)
	}
}
