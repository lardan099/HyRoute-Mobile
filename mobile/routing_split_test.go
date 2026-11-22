package mobile

import (
	"encoding/json"
	"slices"
	"testing"
)

func TestAndroidSplitRoutingUsesDifferentProfiles(t *testing.T) {
	const configuration = `{
	  "defaultAction":"direct",
	  "viaProfiles":{"exit":"entry","backup":"second-entry"},
	  "rules":[
	    {"name":"Messenger","apps":[{"kind":"package","pattern":"org.example.Chat"}],"action":"tunnel","profile":"exit","fallback":["backup"]},
	    {"name":"Browser","apps":[{"kind":"package","pattern":"org.example.browser"}],"action":"tunnel","profile":"browser-vpn"}
	  ]
	}`
	router, err := NewAndroidRouter(configuration, "")
	if err != nil {
		t.Fatal(err)
	}
	if got := router.AndroidPackages(); got != "org.example.Chat\norg.example.browser" {
		t.Errorf("unexpected Android package list %q", got)
	}
	const target = "192.0.2.1:443"
	raw, err := router.DecideForAppWithDNS(target, "tcp", "[]", "org.example.Chat", true)
	if err != nil {
		t.Fatal(err)
	}
	var got routeDecision
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatal(err)
	}
	if got.Action != "tunnel" || got.ServerID != "exit" ||
		!slices.Equal(got.Chain, []string{"entry", "exit"}) ||
		!slices.Equal(got.Fallback, []string{"backup"}) {
		t.Errorf("unexpected messenger route %s", raw)
	}
	fallback, err := router.ProfileChain("backup")
	if err != nil || fallback != `["second-entry","backup"]` {
		t.Errorf("unexpected fallback chain %s (%v)", fallback, err)
	}
	for _, test := range []struct {
		packageID, action, serverID string
	}{
		{"org.example.browser", "tunnel", "browser-vpn"},
		{"org.example.chat", "direct", ""},
		{"", "direct", ""},
	} {
		raw, err := router.DecideForApp(target, "udp", "", test.packageID, true)
		if err != nil {
			t.Fatal(err)
		}
		var route routeDecision
		if err := json.Unmarshal([]byte(raw), &route); err != nil {
			t.Fatal(err)
		}
		if route.Action != test.action || route.ServerID != test.serverID {
			t.Errorf("package %q took route %s", test.packageID, raw)
		}
	}
	if _, err := router.Decide(target, "tcp", ""); err == nil {
		t.Error("an unattributed flow bypassed Android package rules")
	}
	if _, err := NewRouter(configuration, ""); err == nil {
		t.Error("the destination-only router accepted Android package rules")
	}
}

func TestDestinationRoutingAppliesProfileChain(t *testing.T) {
	router, err := NewRouter(`{
	  "defaultAction":"direct",
	  "viaProfiles":{"exit":"middle","middle":"entry"},
	  "rules":[{"domains":[".example.org"],"action":"tunnel","profile":"exit"}]
	}`, "")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := router.Decide("[2001:db8::1]:443", "tcp", "www.example.org")
	if err != nil {
		t.Fatal(err)
	}
	var got routeDecision
	if err := json.Unmarshal([]byte(raw), &got); err != nil {
		t.Fatal(err)
	}
	if got.ServerID != "exit" || !slices.Equal(got.Chain, []string{"entry", "middle", "exit"}) {
		t.Errorf("unexpected destination route %s", raw)
	}
}

func TestRoutingRejectsProfileCycles(t *testing.T) {
	for _, config := range []string{
		`{"viaProfiles":{"a":"a"}}`,
		`{"viaProfiles":{"a":"b","b":"c","c":"a"}}`,
		`{"viaProfiles":{"a":""}}`,
	} {
		if _, err := NewRouter(config, "a"); err == nil {
			t.Errorf("accepted invalid profile chain %s", config)
		}
	}
}
