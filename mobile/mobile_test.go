package mobile

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/lardan099/hyroute-mobile/internal/rules"
)

func TestImportSubscription(t *testing.T) {
	const link = "hy2://example-password@nl.example:443#NL"
	const uuid = "bf43c723-c24b-4c7c-9d41-b8841c6633c9"
	for _, test := range []struct {
		name   string
		body   string
		format string
		hosts  []string
	}{
		{
			name: "links", body: link, format: "links", hosts: []string{"nl.example"},
		},
		{
			name: "base64", body: base64.RawStdEncoding.EncodeToString([]byte(link)),
			format: "base64", hosts: []string{"nl.example"},
		},
		{
			name: "Clash",
			body: `# Ignore this share link hy2://example-password@extra.example:443
proxies:
  - {name: NL, type: hysteria2, server: nl.example, port: 443, password: example-password}
proxy-groups:
  - {name: Provider, type: select, proxies: [NL, DIRECT]}
rules:
  - MATCH,DIRECT
`,
			format: "Clash", hosts: []string{"nl.example"},
		},
		{
			name: "sing-box",
			body: `{"outbounds":[
               {"type":"hysteria2","tag":"NL","server":"nl.example","server_port":443,"password":"example-password"},
               {"type":"selector","tag":"provider","outbounds":["NL","direct"]},
               {"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`,
			format: "sing-box", hosts: []string{"nl.example"},
		},
		{
			name: "Xray with provider routing",
			body: `{"outbounds":[
               {"protocol":"vless","tag":"NL","settings":{"address":"nl.example","port":443,"id":"` + uuid + `"},
                "streamSettings":{"security":"tls"}},
               {"protocol":"vless","tag":"DE","settings":{"address":"de.example","port":443,"id":"` + uuid + `"},
                "streamSettings":{"security":"tls"}},
               {"protocol":"freedom","tag":"direct"}],
               "routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"direct"}]}}`,
			format: "Xray", hosts: []string{"nl.example", "de.example"},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			raw, err := ImportSubscription([]byte(test.body))
			if err != nil {
				t.Fatal(err)
			}
			var got importedSubscription
			if err := json.Unmarshal([]byte(raw), &got); err != nil {
				t.Fatal(err)
			}
			var hosts []string
			for _, server := range got.Servers {
				hosts = append(hosts, server.Host)
				if server.Balance != nil {
					t.Error("imported a provider balancer")
				}
			}
			if got.Format != test.format || !slices.Equal(hosts, test.hosts) {
				t.Errorf("format %q, hosts %v, want %q, %v", got.Format, hosts, test.format, test.hosts)
			}
		})
	}
}

const testXrayBalance = `{
	  "remarks":"Автовыбор",
	  "inbounds":[{"protocol":"socks","listen":"0.0.0.0","port":32100}],
	  "outbounds":[
	    {"protocol":"vless","tag":"node-nl","settings":{"address":"nl.example","port":443,"id":"test-nl"},"streamSettings":{"security":"tls"}},
	    {"protocol":"vless","tag":"node-de","settings":{"address":"de.example","port":443,"id":"test-de"},"streamSettings":{"security":"tls"}}],
	  "routing":{"balancers":[{"tag":"auto","selector":["node-"],"strategy":{"type":"leastLoad"}}],
	             "rules":[{"type":"field","network":"tcp,udp","balancerTag":"auto"}]}
	}`

func TestImportSelectableXrayBalance(t *testing.T) {
	raw, err := ImportSubscription([]byte(testXrayBalance))
	if err != nil {
		t.Fatal(err)
	}
	var got importedSubscription
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Servers) != 1 || got.Servers[0].ID == "" || got.Servers[0].Balance == nil || len(got.Servers[0].Balance.Nodes) != 2 {
		t.Fatal("expected one selectable profile with both VLESS servers")
	}
	if strings.Contains(raw, "32100") {
		t.Fatal("imported the provider's listener")
	}
}

const testXrayLeastPing = `{
  "remarks":"⚡️ Автовыбор",
  "inbounds":[{"protocol":"socks","listen":"127.0.0.1","port":32100}],
  "dns":{"servers":["provider-dns.example"]},
  "burstObservatory":{"subjectSelector":["node-"],"pingConfig":{
    "destination":"https://provider-probe.example/check","interval":"30s","timeout":"5s","sampling":3}},
  "outbounds":[
    {"protocol":"vless","tag":"node-nl","settings":{"vnext":[{"address":"nl.example","port":443,"users":[{"id":"test-nl","encryption":"none"}]}]},"streamSettings":{"security":"tls"}},
    {"protocol":"vless","tag":"node-de","settings":{"vnext":[{"address":"de.example","port":443,"users":[{"id":"test-de","encryption":"none"}]}]},"streamSettings":{"security":"tls"}},
    {"protocol":"vless","tag":"node-de-2","settings":{"vnext":[{"address":"second.example","port":443,"users":[{"id":"test-de2","encryption":"none"}]}]},"streamSettings":{"security":"tls"}},
    {"protocol":"freedom","tag":"direct"},
    {"protocol":"dns","tag":"provider-dns"}],
  "routing":{"balancers":[{"tag":"auto","selector":["node-nl","node-de"],"fallbackTag":"node-de","strategy":{"type":"leastPing"}}],
    "rules":[{"type":"field","inboundTag":["socks"],"port":53,"outboundTag":"provider-dns"},
    {"type":"field","domain":["provider-direct.example"],"outboundTag":"direct"},
    {"type":"field","ip":["192.0.2.0/24"],"balancerTag":"auto"},
    {"type":"field","network":"tcp,udp","balancerTag":"auto"}]}
}`

func TestImportPanelLeastPingAsOneProfile(t *testing.T) {
	raw, err := ImportSubscription([]byte(testXrayLeastPing))
	if err != nil {
		t.Fatal(err)
	}
	var imported importedSubscription
	if err := json.Unmarshal([]byte(raw), &imported); err != nil {
		t.Fatal(err)
	}
	if len(imported.Servers) != 1 || imported.Servers[0].Name != "⚡️ Автовыбор" || imported.Servers[0].Balance == nil {
		t.Fatal("expected a single selectable auto profile")
	}
	balance := imported.Servers[0].Balance
	if balance.StrategyName() != "leastPing" || len(balance.Nodes) != 3 || balance.FallbackNode != 2 ||
		balance.ProbeInterval.String() != "30s" || balance.ProbeTimeout.String() != "5s" || balance.ProbeSamples != 3 {
		t.Fatal("lost node selection, fallback or probe settings")
	}
	for _, forbidden := range []string{"32100", "provider-dns.example", "provider-direct.example", "provider-probe.example"} {
		if strings.Contains(raw, forbidden) {
			t.Fatalf("provider configuration leaked into the saved profile: %s", forbidden)
		}
	}
}

func TestPanelBalanceKeepsOrdinaryServers(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.UserAgent(), "Happ/") {
			io.WriteString(w, testXrayLeastPing)
			return
		}
		io.WriteString(w, "vless://example-user@regular.example:443?security=tls#Regular")
	}))
	defer server.Close()
	raw, err := fetchSubscription(server.Client(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	var imported importedSubscription
	if err := json.Unmarshal([]byte(raw), &imported); err != nil {
		t.Fatal(err)
	}
	if len(imported.Servers) != 2 || imported.Servers[0].Balance == nil || imported.Servers[1].Name != "Regular" {
		t.Fatal("expected auto profile alongside the original country profiles")
	}
}

func TestFetchXrayBalanceKeepsWorkingProfileOnFailedProbe(t *testing.T) {
	var supported atomic.Bool
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Profile-Web-Page-Url", "https://example.org/")
		if strings.HasPrefix(r.UserAgent(), "Happ/") && supported.Load() {
			io.WriteString(w, testXrayBalance)
			return
		}
		io.WriteString(w, "vless://test-node@placeholder.example:443?security=tls#Автовыбор")
	}))
	defer server.Close()
	client := *server.Client()
	client.CheckRedirect = subscriptionRedirect

	supported.Store(true)
	saved, err := fetchSubscription(&client, server.URL)
	if err != nil {
		t.Fatal(err)
	}
	var previous importedSubscription
	if err := json.Unmarshal([]byte(saved), &previous); err != nil {
		t.Fatal(err)
	}
	if len(previous.Servers) != 1 || previous.Servers[0].Balance == nil {
		t.Fatal("the alternate Xray response was not used")
	}
	supported.Store(false)
	fresh, err := fetchSubscription(&client, server.URL)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := MergeSubscription(saved, fresh, "[]"); err == nil {
		t.Fatal("accepted a fallback link in place of the saved balancer")
	}
}

func TestMergeSubscriptionRetainsRouteTargets(t *testing.T) {
	const first = "hy2://old@nl.example:443#NL\nhy2://old@de.example:443#DE"
	const second = "hy2://changed@nl.example:443#NL-renamed\nhy2://new@fi.example:443#FI"
	previousJSON, err := ImportSubscription([]byte(first))
	if err != nil {
		t.Fatal(err)
	}
	var previous importedSubscription
	if err := json.Unmarshal([]byte(previousJSON), &previous); err != nil {
		t.Fatal(err)
	}
	freshJSON, err := ImportSubscription([]byte(second))
	if err != nil {
		t.Fatal(err)
	}
	refs, err := json.Marshal([]string{previous.Servers[1].ID})
	if err != nil {
		t.Fatal(err)
	}
	mergedJSON, err := MergeSubscription(previousJSON, freshJSON, string(refs))
	if err != nil {
		t.Fatal(err)
	}
	var merged importedSubscription
	if err := json.Unmarshal([]byte(mergedJSON), &merged); err != nil {
		t.Fatal(err)
	}
	if len(merged.Servers) != 3 || merged.Servers[0].ID != previous.Servers[0].ID || merged.Servers[0].Auth != "changed" ||
		merged.Servers[2].ID != previous.Servers[1].ID || !merged.Servers[2].Missing {
		t.Fatal("refresh changed a target ID or discarded a server used by a route")
	}
}

func TestFetchSubscription(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/subscription" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		for _, header := range []string{"Referer", "Authorization"} {
			if r.Header.Get(header) != "" {
				t.Errorf("%s was forwarded to another origin", header)
			}
		}
		w.Header().Set("Profile-Title", "base64:"+base64.StdEncoding.EncodeToString([]byte("  Моя подписка  ")))
		w.Header().Set("Subscription-Userinfo", "download=10, upload=2; total=1024; expire=1800000000000")
		w.Header().Set("Profile-Update-Interval", "12")
		w.Header().Set("Support-Url", "https://support.example/")
		io.WriteString(w, "hy2://example-password@nl.example:443#NL")
	}))
	defer server.Close()
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, password, ok := r.BasicAuth()
		if !ok || user != "subscriber" || password != "example-auth" {
			t.Error("initial request lost subscription authentication")
		}
		http.Redirect(w, r, server.URL+"/subscription", http.StatusFound)
	}))
	defer origin.Close()
	client := *origin.Client()
	client.CheckRedirect = subscriptionRedirect

	raw, err := fetchSubscription(&client, "https://subscriber:example-auth@"+
		strings.TrimPrefix(origin.URL, "https://")+"/example-token?key=example-secret")
	if err != nil {
		t.Fatal(err)
	}
	var got importedSubscription
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Servers) != 1 || got.Servers[0].Host != "nl.example" {
		t.Fatal("subscription server was not imported")
	}
	if got.Title != "Моя подписка" || got.UserInfo != "upload=2; download=10; total=1024; expire=1800000000" ||
		got.UpdateHours != 12 || got.Support != "https://support.example/" {
		t.Fatalf("unexpected subscription metadata: %+v", got.PanelInfo)
	}
}

func TestRejectUnencryptedSubscription(t *testing.T) {
	plain := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("sent a subscription request over HTTP")
	}))
	defer plain.Close()
	tls := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, plain.URL, http.StatusFound)
	}))
	defer tls.Close()
	client := *tls.Client()
	client.CheckRedirect = subscriptionRedirect
	for _, address := range []string{plain.URL, tls.URL} {
		if _, err := fetchSubscription(&client, address); err == nil {
			t.Fatal("accepted an unencrypted subscription")
		}
	}
}

func TestRejectUnauthenticatedHysteriaServers(t *testing.T) {
	const unverified = "hy2://example-password@unverified.example:443?insecure=1"
	const invalidPin = "hy2://example-password@invalid.example:443?insecure=1&pinSHA256=abc"
	const pinned = "hy2://example-password@pinned.example:443?insecure=1&pinSHA256=" +
		"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

	if _, err := ImportSubscription([]byte(unverified)); err == nil {
		t.Fatal("accepted a server without certificate verification")
	}
	raw, err := ImportSubscription([]byte(unverified + "\n" + invalidPin + "\n" + pinned))
	if err != nil {
		t.Fatal(err)
	}
	var got importedSubscription
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatal(err)
	}
	if got.Rejected != 2 || len(got.Servers) != 1 || got.Servers[0].Host != "pinned.example" {
		t.Fatal("expected only the server with a valid pin")
	}
}

func TestRejectLinksInRoutingOnlyConfig(t *testing.T) {
	body := []byte("rules:\n  # example hy2://example-password@extra.example:443\n  - MATCH,DIRECT\n")
	if _, err := ImportSubscription(body); err == nil {
		t.Fatal("link embedded in provider routing was imported")
	}
}

func TestLocalRouting(t *testing.T) {
	router, err := NewRouter(`{"defaultAction":"tunnel","rules":[
		{"id":"direct","name":"Local","domains":[".example.org"],"action":"direct"},
		{"id":"block","name":"UDP","domains":["192.0.2.0/24"],"protocol":"udp","ports":"443","action":"block"},
		{"id":"other","name":"Other server","domains":[".example.net"],"action":"tunnel","profile":"de"}
	]}`, "nl")
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		destination, protocol, domain string
		action                        rules.Action
		serverID, ruleID              string
	}{
		{"192.0.2.1:443", "udp", "WWW.Example.ORG.", rules.Direct, "", "direct"},
		{"[::ffff:192.0.2.1]:443", "udp", "", rules.Block, "", "block"},
		{"192.0.2.1:443", "tcp", "", rules.Tunnel, "nl", ""},
		{"[2001:db8::1]:443", "tcp", "example.net", rules.Tunnel, "de", "other"},
	} {
		raw, err := router.Decide(test.destination, test.protocol, test.domain)
		if err != nil {
			t.Fatal(err)
		}
		var got routeDecision
		if err := json.Unmarshal([]byte(raw), &got); err != nil {
			t.Fatal(err)
		}
		if got.Action != test.action.String() || got.ServerID != test.serverID || got.RuleID != test.ruleID {
			t.Errorf("route for %s %s (%s) = %s", test.protocol, test.destination, test.domain, raw)
		}
	}
}

func TestLocalRoutingWaitsForDomainOnSharedIP(t *testing.T) {
	router, err := NewRouter(`{"defaultAction":"direct","rules":[
		{"name":"VPN","domains":[".example.org"],"action":"tunnel"}
	]}`, "nl")
	if err != nil {
		t.Fatal(err)
	}
	const destination = "192.0.2.1:443"
	raw, err := router.DecideWithDNS(destination, "tcp", `[["private.example.org"],["other.example"]]`)
	if err != nil {
		t.Fatal(err)
	}
	var initial routeDecision
	if err := json.Unmarshal([]byte(raw), &initial); err != nil {
		t.Fatal(err)
	}
	if !initial.NeedsDomain || initial.Action != "" {
		t.Fatalf("expected to wait for the exact domain, got %s", raw)
	}
	raw, err = router.Decide(destination, "tcp", "private.example.org")
	if err != nil {
		t.Fatal(err)
	}
	var resolved routeDecision
	if err := json.Unmarshal([]byte(raw), &resolved); err != nil {
		t.Fatal(err)
	}
	if resolved.NeedsDomain || resolved.Action != "tunnel" || resolved.ServerID != "nl" {
		t.Fatalf("expected the local VPN route, got %s", raw)
	}
}

func TestLocalRoutingRequiresServer(t *testing.T) {
	router, err := NewRouter(`{"defaultAction":"tunnel"}`, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := router.Decide("192.0.2.1:443", "tcp", ""); err == nil {
		t.Fatal("tunnel without selected server was accepted")
	}
}
