package mobile

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/vless"
	xctx "github.com/xtls/xray-core/common/ctx"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/proxy/vless/inbound"
)

func TestVPNRoutesThroughEmbeddedVLESSBalance(t *testing.T) {
	const credential = "00000000-0000-4000-8000-000000000001"
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("hyroute-vpn-test"))
	}))
	defer endpoint.Close()
	socket, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := socket.Addr().(*net.TCPAddr).Port
	_ = socket.Close()
	serverConfig := fmt.Sprintf(`{"log":{"loglevel":"none","access":"none"},
		"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"vless",
		  "settings":{"decryption":"none","clients":[{"id":%q}]}}],
		"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}]}`, port, credential)
	startVPNTestServer(t, serverConfig)
	assertVPNRoundTrip(t, hysteria.Profile{ID: "auto", Name: "Auto", Protocol: hysteria.ProtoVLESS,
		Balance: &vless.Balance{Strategy: "leastPing", FallbackNode: 1, BlockBitTorrent: true, Nodes: []vless.Node{{
			Host: "127.0.0.1", Port: port, Settings: vless.Settings{ID: credential},
		}}}}, endpoint.URL)
	state := clientState{Subscriptions: []savedSubscription{{URL: "https://example.test/secret", Snapshot: importedSubscription{
		Servers: []hysteria.Profile{
			{ID: "primary", Host: "primary.invalid", Ports: "443", Auth: "unresolved"},
			{ID: "reserve", Host: "127.0.0.1", Ports: fmt.Sprint(port), Protocol: hysteria.ProtoVLESS, VLESS: vless.Settings{ID: credential}},
		},
	}}}}
	raw := encodeNetworkTestState(t, state)
	updated, err := ChangeServerGroup(raw, "", `{"name":"Group","primary":["primary"],"reserve":"reserve"}`)
	if err != nil {
		t.Fatal(err)
	}
	state, err = decodeClientState(updated)
	if err != nil {
		t.Fatal(err)
	}
	state.Settings.Selected = state.ServerGroups[0].ID
	raw = encodeNetworkTestState(t, state)
	if _, err := ChangeServerGroup(raw, state.Settings.Selected, ""); err == nil {
		t.Fatal("selected group was deleted")
	}
	recovery, err := VPNRecoveryState(raw)
	if err != nil || strings.Contains(recovery, "example.test/secret") {
		t.Fatalf("recovery must omit subscription URL: %v", err)
	}
	assertVPNStateRoundTrip(t, recovery, endpoint.URL)
}

func TestIOSVPNPlanUsesDisplayedProfileAfterSelectedServerDisappears(t *testing.T) {
	const credential = "00000000-0000-4000-8000-000000000001"
	servers := []hysteria.Profile{
		{ID: "gone", Missing: true},
		{ID: "regular", Host: "127.0.0.1", Ports: "443", Auth: "fixture"},
		{ID: "auto", Protocol: hysteria.ProtoVLESS, Balance: &vless.Balance{Nodes: []vless.Node{{
			Host: "127.0.0.1", Port: 443, Settings: vless.Settings{ID: credential},
		}}}},
	}
	state := clientState{Subscriptions: []savedSubscription{{Snapshot: importedSubscription{Servers: servers}}},
		Settings: clientSettings{Selected: "gone"}}
	check := func(wantProfile, wantIssue string) {
		t.Helper()
		data, err := json.Marshal(state)
		if err != nil {
			t.Fatal(err)
		}
		result := InspectIOSVPNPlan(string(data))
		if result.Issue() != wantIssue {
			t.Fatalf("issue = %q, want %q", result.Issue(), wantIssue)
		}
		if wantProfile != "" && (result.Plan() == nil || result.Plan().selected != wantProfile) {
			t.Fatalf("expected selected profile %q", wantProfile)
		}
	}
	check("auto", "")
	state.Settings.Selected = "regular"
	check("regular", "")
	state.Settings.Routing = json.RawMessage(`{"rules":[{"action":"tunnel","domains":["example.test"],"profile":"gone"}]}`)
	check("", "reference")
	state.Settings.Routing = nil
	state.Subscriptions = nil
	check("", "profile")
}

func TestIOSChainRepairWithExistingUnavailableGeoRules(t *testing.T) {
	ConfigureGeo(t.TempDir())
	state := `{"subscriptions":[{"snapshot":{"servers":[{"id":"active","host":"127.0.0.1","ports":"443","auth":"fixture"}]} }],
		"settings":{"selected":"active","routing":{"defaultAction":"tunnel",
		"rules":[{"action":"direct","domains":["geosite:youtube"]}],"viaProfiles":{"active":"gone"}}}}`
	settings := `{"selected":"active","routing":{"defaultAction":"tunnel",
		"rules":[{"action":"direct","domains":["geosite:youtube"]}]}}`
	updated, err := SaveClientSettings(state, settings, false)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(updated, "gone") {
		t.Fatal("the unavailable link survived explicit removal")
	}
	if issue := InspectIOSVPNPlan(updated).Issue(); issue != "geo" {
		t.Fatalf("starting the VPN must still require geodata, issue = %q", issue)
	}
	changedRules := strings.Replace(settings, "geosite:youtube", "geosite:telegram", 1)
	if _, err := SaveClientSettings(state, changedRules, false); err == nil {
		t.Fatal("a changed rule referencing missing data must still be rejected")
	}

	twoMissing := strings.Replace(updated, `"geosite:youtube"`, `"geosite:youtube","geoip:telegram","geoip:private"`, 1)
	result := InspectIOSVPNPlan(twoMissing)
	if result.Issue() != "geo" || result.GeoCategories() != `["geosite:youtube","geoip:telegram"]` {
		t.Fatalf("geo diagnosis = %q, %q", result.Issue(), result.GeoCategories())
	}
	oneMissing := strings.Replace(settings, `"geosite:youtube"`, `"geoip:telegram","geoip:private"`, 1)
	repaired, err := SaveClientSettings(twoMissing, oneMissing, false)
	if err != nil {
		t.Fatal(err)
	}
	if issue := InspectIOSVPNPlan(repaired).Issue(); issue != "geo" {
		t.Fatalf("remaining unavailable category must still block startup, issue = %q", issue)
	}
	if _, err := SaveClientSettings(twoMissing, changedRules, false); err == nil {
		t.Fatal("a partial repair cannot introduce a new unavailable category")
	}
	repaired, err = SaveClientSettings(repaired, strings.Replace(oneMissing, `"geoip:telegram",`, "", 1), false)
	if err != nil {
		t.Fatal(err)
	}
	if issue := InspectIOSVPNPlan(repaired).Issue(); issue != "" {
		t.Fatalf("repaired routing must allow startup, issue = %q", issue)
	}
}

func TestIOSRejectsCycleThroughGroupMember(t *testing.T) {
	raw := `{"subscriptions":[{"snapshot":{"servers":[
		{"id":"moscow","name":"Москва","host":"192.0.2.1","ports":"443","auth":"local"},
		{"id":"other","name":"Запасной","host":"192.0.2.2","ports":"443","auth":"local"}]}}],
		"settings":{"selected":"moscow"},
		"serverGroups":[{"id":"entry","name":"Вход","primary":["moscow"],"reserve":"other"}]}`
	settings := `{"selected":"moscow","routing":{"defaultAction":"tunnel","viaProfiles":{"moscow":"entry"}}}`
	if _, err := SaveClientSettings(raw, settings, false); err == nil ||
		!strings.Contains(err.Error(), "Цепочка замыкается") ||
		!strings.Contains(err.Error(), "Москва") || !strings.Contains(err.Error(), "Вход") {
		t.Fatalf("wanted specific cycle through a group member, got %v", err)
	}
}

func TestVPNRoutesThroughEmbeddedHysteria(t *testing.T) {
	const auth = "local-hysteria-test"
	response := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("hyroute-vpn-test"))
	})
	endpoint := httptest.NewServer(response)
	defer endpoint.Close()
	tlsFixture := httptest.NewTLSServer(response)
	defer tlsFixture.Close()
	cert := tlsFixture.TLS.Certificates[0]
	key, err := x509.MarshalPKCS8PrivateKey(cert.PrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := socket.LocalAddr().(*net.UDPAddr).Port
	_ = socket.Close()
	serverConfig := fmt.Sprintf(`{"log":{"loglevel":"none","access":"none"},
		"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"hysteria",
		  "settings":{"version":2,"clients":[{"auth":%q}]},
		  "streamSettings":{"network":"hysteria","security":"tls","hysteriaSettings":{"version":2},
		  "tlsSettings":{"alpn":["h3"],"certificates":[{"certificate":[%q],"key":[%q]}]}}}],
		"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}]}`,
		port, auth, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: key}))
	startVPNTestServer(t, serverConfig)
	exit := hysteria.Profile{ID: "hy2", Name: "Hysteria test", Host: "127.0.0.1",
		Ports: fmt.Sprint(port), Auth: auth, TLS: hysteria.TLS{PinSHA256: fmt.Sprintf("%x", sha256.Sum256(cert.Certificate[0]))},
	}
	t.Run("Single", func(t *testing.T) { assertVPNRoundTrip(t, exit, endpoint.URL) })
	t.Run("ViaGroupReserve", func(t *testing.T) {
		const credential = "00000000-0000-4000-8000-000000000002"
		upstream, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		entryPort := upstream.Addr().(*net.TCPAddr).Port
		_ = upstream.Close()
		startVPNTestServer(t, fmt.Sprintf(`{"log":{"loglevel":"none","access":"none"},
			"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"vless",
			  "settings":{"decryption":"none","clients":[{"id":%q}]}}],
			"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}]}`,
			entryPort, credential))
		state := clientState{
			Subscriptions: []savedSubscription{{Snapshot: importedSubscription{Servers: []hysteria.Profile{
				exit, {ID: "primary", Host: "primary.invalid", Ports: "443", Auth: "unresolved"},
				{ID: "auto", Name: "Imported Auto", Protocol: hysteria.ProtoVLESS, Balance: &vless.Balance{
					FallbackNode: 1, Strategy: "leastPing", Nodes: []vless.Node{{
						Host: "127.0.0.1", Port: entryPort, Settings: vless.Settings{ID: credential},
					}},
				}},
			}}}},
			Settings: clientSettings{Selected: exit.ID},
		}
		candidates, ordered := state.groupCandidates()
		if len(ordered) != 3 || candidates[ordered[2]].node == nil {
			t.Fatalf("imported Auto node missing from group picker: %v", ordered)
		}
		state.ServerGroups = []serverGroup{{ID: "group", Name: "First hop", Primary: []string{"primary"}, Reserve: ordered[2]}}
		state.Settings.Routing = json.RawMessage(`{"defaultAction":"tunnel","viaProfiles":{"hy2":"group"}}`)
		journal := assertVPNStateRoundTripWithLog(t, encodeNetworkTestState(t, state), endpoint.URL, func(active *core.Instance) {
			probe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(http.StatusNoContent)
			}))
			defer probe.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			status, _ := (probeTarget{node: candidates[ordered[2]].node}).measure(ctx, probe.URL, active)
			if status != "ok" {
				t.Fatalf("test via temporary outbound in active VPN: %s", status)
			}
		})
		trace := journal.snapshot()
		var events []trafficEvent
		if err := json.Unmarshal([]byte(trace), &events); err != nil {
			t.Fatal(err)
		}
		var route, reserve bool
		for _, event := range events {
			if event.Flow != 17 {
				t.Fatalf("unexpected observation or unrelated flow in trace: %s", trace)
			}
			route = route || event.Stage == "route" && event.Profile == exit.Name && event.Rule == "Остальной трафик"
			reserve = reserve || event.Stage == "hop" && strings.Contains(event.Profile, "First hop · Imported Auto") &&
				strings.Contains(event.Profile, "(резерв)")
		}
		if !route || !reserve || strings.Contains(trace, credential) || strings.Contains(trace, auth) {
			t.Fatalf("want correlated route and actual reserve without credentials: %s", trace)
		}
		t.Run("RecoverStalledUDP", func(t *testing.T) {
			relay, stall := stallableUDPRelay(t, netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(port)))
			state.Subscriptions[0].Snapshot.Servers[0].Ports = fmt.Sprint(relay.Port())
			testVPNChainRecovery(t, encodeNetworkTestState(t, state), endpoint.URL, stall)
		})
	})
}

// The relay drops packets from the original Hysteria UDP socket but still
// serves a fresh socket after recovery.
func stallableUDPRelay(t *testing.T, server netip.AddrPort) (netip.AddrPort, func()) {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	var stalled atomic.Bool
	go func() {
		data := make([]byte, 65535)
		var client, old netip.AddrPort
		for {
			n, from, err := conn.ReadFromUDPAddrPort(data)
			if err != nil {
				return
			}
			if stalled.Load() && !old.IsValid() {
				old = client
			}
			if from == server {
				if client.IsValid() && client != old {
					_, _ = conn.WriteToUDPAddrPort(data[:n], client)
				}
			} else if from != old {
				client = from
				_, _ = conn.WriteToUDPAddrPort(data[:n], server)
			}
		}
	}()
	return conn.LocalAddr().(*net.UDPAddr).AddrPort(), func() { stalled.Store(true) }
}

func testVPNChainRecovery(t *testing.T, raw, endpoint string, stall func()) {
	t.Helper()
	plan, err := NewVPNPlan(raw, false)
	if err != nil {
		t.Fatal(err)
	}
	config, err := plan.configuration(t.Context(), false, vpnResolveForTest)
	if err != nil {
		t.Fatal(err)
	}
	start := func() *VPNSession {
		ctx, cancel := context.WithCancel(t.Context())
		config.health.restart()
		instance, err := config.start(ctx, nil)
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		t.Cleanup(func() {
			cancel()
			if instance.IsRunning() {
				_ = instance.Close()
			}
		})
		return &VPNSession{ctx: ctx, cancel: cancel, instance: instance, health: config.health}
	}
	first := start()
	if got := first.checkChains(time.Second, endpoint); got != "idle" {
		t.Fatalf("must wait for user traffic, got %q", got)
	}
	user := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + addr)
			if err != nil {
				return nil, err
			}
			ctx = xctx.ContextWithID(ctx, 21)
			ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: "hyroute-tun"})
			return core.Dial(ctx, first.instance, dest)
		},
	}}
	response, err := user.Get(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if got := first.checkChains(2*time.Second, endpoint); got != "healthy" {
		t.Fatalf("working chain reported %q", got)
	}
	stall()
	for _, want := range []string{"failed", "restart"} {
		if got := first.checkChains(400*time.Millisecond, endpoint); got != want {
			t.Fatalf("silently stalled UDP chain reported %q, want %q", got, want)
		}
	}
	if !first.instance.IsRunning() {
		t.Fatal("the first engine must still be running during the silent transport stall")
	}
	first.cancel()
	if err := first.instance.Close(); err != nil {
		t.Fatal(err)
	}
	if got := start().checkChains(3*time.Second, endpoint); got != "healthy" {
		t.Fatalf("fresh chain must work while the original UDP socket is still blocked, got %q", got)
	}
}

func vpnResolveForTest(_ context.Context, host string) netip.Addr {
	ip, _ := netip.ParseAddr(host)
	return ip
}

func startVPNTestServer(t *testing.T, raw string) {
	t.Helper()
	config, err := core.LoadConfig("json", strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	server, err := core.New(config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = server.Close() })
	if err = server.Start(); err != nil {
		t.Fatal(err)
	}
}

func assertVPNRoundTrip(t *testing.T, profile hysteria.Profile, target string) {
	t.Helper()
	state := clientState{Subscriptions: []savedSubscription{{Snapshot: importedSubscription{
		Servers: []hysteria.Profile{profile},
	}}}, Settings: clientSettings{Selected: profile.ID}}
	assertVPNStateRoundTrip(t, encodeNetworkTestState(t, state), target)
}

func encodeNetworkTestState(t *testing.T, state clientState) string {
	t.Helper()
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func assertVPNStateRoundTrip(t *testing.T, raw, target string) {
	t.Helper()
	assertVPNStateRoundTripWithLog(t, raw, target, nil)
}

func assertVPNStateRoundTripWithLog(t *testing.T, raw, target string, before func(*core.Instance)) *trafficJournal {
	t.Helper()
	plan, err := NewVPNPlan(raw, false)
	if err != nil {
		t.Fatal(err)
	}
	clientConfig, err := plan.configuration(context.Background(), false, vpnResolveForTest)
	if err != nil {
		t.Fatal(err)
	}
	if clientConfig.xray["inbounds"] != nil {
		t.Fatal("unexpected client listener")
	}
	if strings.Contains(fmt.Sprint(clientConfig.xray["routing"]), "bittorrent") {
		t.Fatal("subscription routing must not override the user")
	}
	if before != nil {
		clientConfig.traffic.enabled.Store(true)
	}
	engine, err := clientConfig.start(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	if before != nil {
		before(engine)
	}
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
			ctx = xctx.ContextWithID(ctx, 17)
			ctx = session.ContextWithInbound(ctx, &session.Inbound{Tag: "hyroute-tun"})
			dest, err := xnet.ParseDestination("tcp:" + address)
			if err != nil {
				return nil, err
			}
			return core.Dial(ctx, engine, dest)
		},
	}}
	response, err := client.Get(target)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "hyroute-vpn-test" {
		t.Fatalf("request did not reach the VPN egress: %v", err)
	}
	return clientConfig.traffic
}
