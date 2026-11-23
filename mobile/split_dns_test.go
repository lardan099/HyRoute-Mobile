package mobile

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/vless"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/proxy"
	"golang.org/x/net/dns/dnsmessage"
)

func TestSplitDNSViaEmbeddedVPN(t *testing.T) {
	const credential = "00000000-0000-4000-8000-000000000002"
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	startVPNTestServer(t, fmt.Sprintf(`{"log":{"loglevel":"none"},
		"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"vless",
		  "settings":{"decryption":"none","clients":[{"id":%q}]}}],
		"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}]}`, port, credential))

	var tunnelCount, directCount atomic.Int32
	resolver := func(label string, calls *atomic.Int32) *httptest.Server {
		server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			calls.Add(1)
			raw, _ := io.ReadAll(r.Body)
			var query dnsmessage.Message
			if query.Unpack(raw) != nil || len(query.Questions) != 1 || r.Header.Get("Content-Type") != dnsMessageType {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			if query.Questions[0].Name.String() == "fail.direct.example." {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			query.Response = true
			query.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{
				Name: query.Questions[0].Name, Class: dnsmessage.ClassINET, TTL: 30,
			}, Body: &dnsmessage.TXTResource{TXT: []string{label}}}}
			data, _ := query.Pack()
			w.Header().Set("Content-Type", dnsMessageType)
			_, _ = w.Write(data)
		}))
		t.Cleanup(server.Close)
		return server
	}
	tunnelServer := resolver("vpn", &tunnelCount)
	directServer := resolver("direct", &directCount)
	profile := hysteria.Profile{ID: "vpn", Host: "127.0.0.1", Ports: fmt.Sprint(port),
		Protocol: hysteria.ProtoVLESS, VLESS: vless.Settings{ID: credential}}
	state := clientState{Subscriptions: []savedSubscription{{Snapshot: importedSubscription{Servers: []hysteria.Profile{profile}}}},
		Settings: clientSettings{Selected: profile.ID, SplitDNS: &splitDNSSettings{
			Tunnel: "https://1.1.1.1/dns-query", Direct: "https://8.8.8.8/dns-query", Domains: []string{"Direct.Example"},
		}}}
	plan, err := NewVPNPlan(encodeNetworkTestState(t, state), false)
	if err != nil {
		t.Fatal(err)
	}
	plan.splitDNS.Tunnel, plan.splitDNS.Direct = tunnelServer.URL, directServer.URL
	config, err := plan.configuration(context.Background(), false, func(_ context.Context, host string) netip.Addr {
		return netip.MustParseAddr(host)
	})
	if err != nil {
		t.Fatal(err)
	}
	config.xray["outbounds"].([]any)[1].(map[string]any)["settings"] = map[string]any{
		"finalRules": []any{map[string]any{"action": "allow", "ip": []string{"127.0.0.1/32"}}},
	}
	engine, err := config.start(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = engine.Close() })
	manager := engine.GetFeature(outbound.ManagerType()).(outbound.Manager)
	handler := manager.GetHandler(splitDNSTag).(proxy.GetOutbound).GetOutbound().(*trafficOutbound).Outbound.(*splitDNSProxy)
	for client, server := range map[*http.Client]*httptest.Server{handler.tunnel: tunnelServer, handler.direct: directServer} {
		roots := x509.NewCertPool()
		roots.AddCert(server.Certificate())
		client.Transport.(*http.Transport).TLSClientConfig = &tls.Config{RootCAs: roots}
	}
	query := func(domain string) dnsmessage.Message {
		t.Helper()
		request := dnsmessage.Message{Header: dnsmessage.Header{ID: 42, RecursionDesired: true}, Questions: []dnsmessage.Question{{
			Name: dnsmessage.MustNewName(domain), Type: dnsmessage.TypeTXT, Class: dnsmessage.ClassINET,
		}}}
		packet, _ := request.Pack()
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		conn, err := core.Dial(ctx, engine, xnet.TCPDestination(xnet.ParseAddress(vpnDNS), 53))
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
		defer stop()
		if _, err := conn.Write(binary.BigEndian.AppendUint16(nil, uint16(len(packet)))); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Write(packet); err != nil {
			t.Fatal(err)
		}
		var size uint16
		if err := binary.Read(conn, binary.BigEndian, &size); err != nil {
			t.Fatal(err)
		}
		response := make([]byte, size)
		if _, err := io.ReadFull(conn, response); err != nil {
			t.Fatal(err)
		}
		var answer dnsmessage.Message
		if err := answer.Unpack(response); err != nil {
			t.Fatal(err)
		}
		return answer
	}
	for domain, want := range map[string]string{"sub.direct.example.": "direct", "other-direct.example.": "vpn"} {
		answer := query(domain)
		if len(answer.Answers) != 1 || answer.Answers[0].Body.(*dnsmessage.TXTResource).TXT[0] != want {
			t.Fatalf("incorrect resolver for %s: %v", domain, answer)
		}
	}
	if answer := query("fail.direct.example."); answer.RCode != dnsmessage.RCodeServerFailure {
		t.Fatalf("expected SERVFAIL: %v", answer)
	}
	if tunnelCount.Load() != 1 || directCount.Load() != 2 {
		t.Fatal("DNS failed over to the wrong resolver")
	}
}
