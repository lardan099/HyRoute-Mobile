package mobile

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/vless"
)

func TestProbeChecksEachGroupMemberAndSingleProfile(t *testing.T) {
	const credential = "00000000-0000-4000-8000-000000000001"
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer endpoint.Close()
	socket, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := socket.Addr().(*net.TCPAddr).Port
	_ = socket.Close()
	startVPNTestServer(t, fmt.Sprintf(`{"log":{"loglevel":"none"},
		"inbounds":[{"listen":"127.0.0.1","port":%d,"protocol":"vless",
		  "settings":{"decryption":"none","clients":[{"id":%q}]}}],
		"outbounds":[{"protocol":"freedom","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}]}`, port, credential))
	single := hysteria.Profile{ID: "member", Name: "Тест", Protocol: hysteria.ProtoVLESS,
		Host: "127.0.0.1", Ports: fmt.Sprint(port), VLESS: vless.Settings{ID: credential}}
	group := hysteria.Profile{ID: "group", Name: "Группа", Protocol: hysteria.ProtoVLESS,
		Balance: &vless.Balance{Nodes: []vless.Node{
			{Host: single.Host, Port: port, Settings: single.VLESS},
			{Host: single.Host, Port: port, Settings: vless.Settings{}},
		}}}
	raw, err := json.Marshal(clientState{Subscriptions: []savedSubscription{{ID: "sub",
		Snapshot: importedSubscription{Servers: []hysteria.Profile{single, group}},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	journal := filepath.Join(t.TempDir(), "vpn.json")
	for _, tc := range []struct {
		scope, id string
		count     int
	}{{"profile", "member", 1}, {"profile", "group", 2}, {"subscription", "sub", 3}} {
		batch, err := startProbe(string(raw), tc.scope, tc.id, journal, endpoint.URL)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(batch.Cancel)
		deadline := time.Now().Add(3 * time.Second)
		var result struct {
			Done    bool
			Results []probeResult
		}
		for !result.Done && time.Now().Before(deadline) {
			if err := json.Unmarshal([]byte(batch.Snapshot()), &result); err != nil {
				t.Fatal(err)
			}
			time.Sleep(5 * time.Millisecond)
		}
		if !result.Done || len(result.Results) != tc.count || result.Results[0].Status != "ok" || result.Results[0].Millis < 1 {
			t.Fatalf("measurement failed for %s: %+v", tc.id, result)
		}
		if tc.count > 1 && result.Results[tc.count-1].Status != "configuration" {
			t.Fatalf("a bad node affected the results for %s: %+v", tc.id, result)
		}
	}
	if log := VPNJournal(journal, ""); strings.Contains(log, credential) || strings.Contains(log, single.Host) || !strings.Contains(log, journalMessages["probe_done"]) {
		t.Fatalf("unexpected journal: %s", log)
	}
}

func TestVPNJournalLimitsAndValidatesEvents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "journal.json")
	RecordVPNEvent(path, "vpn_request")
	for range journalLimit {
		RecordVPNEvent(path, "vpn_running")
	}
	RecordVPNEvent(path, "https://private.example/secret")
	entries := readJournal(path)
	if len(entries) != journalLimit || entries[0].Event != "vpn_running" || entries[len(entries)-1].Event != "vpn_running" {
		t.Fatal("journal did not keep only the newest known events")
	}
}
