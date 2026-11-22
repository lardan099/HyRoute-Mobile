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
	"testing"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/vless"
	xnet "github.com/xtls/xray-core/common/net"
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
		Balance: &vless.Balance{Strategy: "leastPing", FallbackNode: 1, Nodes: []vless.Node{{
			Host: "127.0.0.1", Port: port, Settings: vless.Settings{ID: credential},
		}}}}, endpoint.URL)
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
	assertVPNRoundTrip(t, hysteria.Profile{ID: "hy2", Name: "Hysteria test", Host: "127.0.0.1",
		Ports: fmt.Sprint(port), Auth: auth, TLS: hysteria.TLS{PinSHA256: fmt.Sprintf("%x", sha256.Sum256(cert.Certificate[0]))},
	}, endpoint.URL)
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
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := NewVPNPlan(string(raw), false)
	if err != nil {
		t.Fatal(err)
	}
	clientConfig, err := plan.configuration(context.Background(), false, func(_ context.Context, host string) netip.Addr {
		return netip.MustParseAddr(host)
	})
	if err != nil {
		t.Fatal(err)
	}
	if clientConfig.xray["inbounds"] != nil {
		t.Fatal("unexpected client listener")
	}
	engine, err := clientConfig.start(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Close()
	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
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
}
