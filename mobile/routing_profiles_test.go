package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

const testRoutingState = `{"subscriptions":[{"id":"sub","snapshot":{"servers":[
	{"id":"entry","host":"192.0.2.1","ports":"443","auth":"fixture"},
	{"id":"exit","host":"192.0.2.2","ports":"443","auth":"fixture"}
]}}],"settings":{"selected":"entry","routing":{"defaultAction":"direct",
	"rules":[{"name":"Сайт","action":"tunnel","domains":["example.org"],"profile":"exit"}],
	"viaProfiles":{"exit":"entry"}}}}`

func TestRoutingProfilesKeepIndependentRulesAndRestoreOldSettings(t *testing.T) {
	raw := testRoutingState
	change := func(action, id, name string) {
		t.Helper()
		updated, err := ChangeRoutingProfile(raw, action, id, name)
		if err != nil {
			t.Fatal(err)
		}
		raw = updated
	}
	read := func() clientState {
		t.Helper()
		state, err := decodeClientState(raw)
		if err != nil {
			t.Fatal(err)
		}
		return state
	}
	if state := read(); state.activeRoutingID() != defaultRoutingProfile || state.routingProfileViews()[0].RuleCount != 1 {
		t.Fatal("existing settings must appear as the default profile")
	}
	change("copy", "", "Работа")
	workID := read().activeRoutingID()
	if workID == defaultRoutingProfile {
		t.Fatal("copy was not activated")
	}
	next, err := SaveClientSettings(raw, `{"selected":"entry","routing":{"defaultAction":"block","rules":[]}}`, false)
	if err != nil {
		t.Fatal(err)
	}
	raw = next
	change("activate", defaultRoutingProfile, "")
	if config := string(read().Settings.Routing); !strings.Contains(config, "example.org") || !strings.Contains(config, "viaProfiles") {
		t.Fatalf("original routing was not restored: %s", config)
	}
	change("rename", workID, "Офис")
	change("activate", workID, "")
	if !strings.Contains(string(read().Settings.Routing), `"defaultAction":"block"`) {
		t.Fatal("edits to the copied profile were not retained")
	}
	if _, err := ChangeRoutingProfile(raw, "delete", workID, ""); err == nil {
		t.Fatal("active rules must not disappear on delete")
	}
	change("activate", defaultRoutingProfile, "")
	change("delete", workID, "")
	if state := read(); len(state.RoutingProfiles) != 1 || state.Settings.Selected != "entry" {
		t.Fatal("removing the copy changed the primary VPN profile")
	}
}

func TestRouteCheckUsesActiveRoutingAndAndroidScope(t *testing.T) {
	check := func(raw, address, ip, app string, android bool) checkedRoute {
		t.Helper()
		result, err := CheckClientRoute(raw, address, ip, "tcp", app, android)
		if err != nil {
			t.Fatal(err)
		}
		var route checkedRoute
		if err := json.Unmarshal([]byte(result), &route); err != nil {
			t.Fatal(err)
		}
		return route
	}
	route := check(testRoutingState, "https://example.org/path?secret=value", "", "", false)
	if route.Target != "example.org:443" || route.Action != "tunnel" || route.Rule != "Сайт" ||
		strings.Join(route.Chain, ",") != "entry,exit" {
		t.Fatalf("incorrect result: %+v", route)
	}
	if route := check(testRoutingState, "[2001:db8::1]:8443", "", "", false); route.Target != "[2001:db8::1]:8443" || route.Action != "direct" {
		t.Fatalf("incorrect IPv6 default route: %+v", route)
	}
	scoped := strings.Replace(testRoutingState, `"selected":"entry","routing"`, `"selected":"entry","appScope":"only","appPackages":["com.example.app"],"routing"`, 1)
	if _, err := CheckClientRoute(scoped, "example.org", "", "tcp", "", true); err == nil {
		t.Fatal("scope check silently ignored Android application")
	}
	if route := check(scoped, "example.org", "", "com.example.other", true); route.Action != "direct" || route.Rule != "Приложение вне VPN" {
		t.Fatalf("excluded app routed inside the VPN: %+v", route)
	}
	dns := check(testRoutingState, "1.1.1.1:53", "", "", false)
	if dns.Rule != "Системный DNS" || strings.Join(dns.Chain, ",") != "entry" {
		t.Fatalf("DNS policy did not match the tunnel: %+v", dns)
	}
}

func TestSubscriptionRefreshPreservesProfilesReferencedByInactiveRules(t *testing.T) {
	raw, err := ChangeRoutingProfile(testRoutingState, "copy", "", "Работа")
	if err != nil {
		t.Fatal(err)
	}
	raw, err = SaveClientSettings(raw, `{"selected":"entry","routing":{"defaultAction":"direct","rules":[]}}`, false)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeClientState(raw)
	if err != nil {
		t.Fatal(err)
	}
	fresh, err := ImportSubscription([]byte("hysteria2://fixture@192.0.2.3:443#Replacement"))
	if err != nil {
		t.Fatal(err)
	}
	raw, err = mergeClientSubscription(state, 0, fresh)
	if err != nil {
		t.Fatal(err)
	}
	state, err = decodeClientState(raw)
	if err != nil {
		t.Fatal(err)
	}
	for _, profile := range state.Subscriptions[0].Snapshot.Servers {
		if profile.ID == "exit" && profile.Missing {
			return
		}
	}
	t.Fatal("refresh dropped the reference stored in inactive rules")
}
