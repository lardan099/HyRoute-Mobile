package mobile

import (
	"context"
	"encoding/json"
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
	config, err := core.LoadConfig("json", strings.NewReader(serverConfig))
	if err != nil {
		t.Fatal(err)
	}
	server, err := core.New(config)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	if err = server.Start(); err != nil {
		t.Fatal(err)
	}
	state := clientState{Subscriptions: []savedSubscription{{Snapshot: importedSubscription{
		Servers: []hysteria.Profile{{ID: "auto", Name: "Auto", Protocol: hysteria.ProtoVLESS,
			Balance: &vless.Balance{Strategy: "leastPing", FallbackNode: 1, Nodes: []vless.Node{{
				Host: "127.0.0.1", Port: port, Settings: vless.Settings{ID: credential},
			}}}}},
	}}}, Settings: clientSettings{Selected: "auto"}}
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
	response, err := client.Get(endpoint.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || string(body) != "hyroute-vpn-test" {
		t.Fatalf("request did not reach the VLESS egress: %v", err)
	}
}
