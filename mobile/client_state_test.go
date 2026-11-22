package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRefreshSnapshotAddsAutoWithoutChangingExistingSelection(t *testing.T) {
	const ordinary = "vless://test-user@regular.example:443?security=tls#Regular"
	raw, err := AddClientSubscription("", ordinary, false)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeClientState(raw)
	if err != nil {
		t.Fatal(err)
	}
	state.Subscriptions[0].URL = "https://example.org/subscription-token"
	id := state.Subscriptions[0].ID
	selected := state.Settings.Selected
	base, err := ImportSubscription([]byte(ordinary))
	if err != nil {
		t.Fatal(err)
	}
	alternate, err := ImportSubscription([]byte(testXrayLeastPing))
	if err != nil {
		t.Fatal(err)
	}
	var panel importedSubscription
	if err := json.Unmarshal([]byte(alternate), &panel); err != nil {
		t.Fatal(err)
	}
	fresh, err := appendPanelBalances(base, panel.Servers)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := mergeClientSubscription(state, 0, fresh)
	if err != nil {
		t.Fatal(err)
	}
	view, err := ClientStateView(updated)
	if err != nil {
		t.Fatal(err)
	}
	var displayed struct {
		Subscriptions []subscriptionPreview `json:"subscriptions"`
		Settings      clientSettings        `json:"settings"`
	}
	if err := json.Unmarshal([]byte(view), &displayed); err != nil {
		t.Fatal(err)
	}
	item := displayed.Subscriptions[0]
	if item.ID != id || !item.CanRefresh || len(item.Servers) != 2 || item.Servers[0].BalanceStrategy != "leastPing" ||
		item.Servers[1].ID != selected || displayed.Settings.Selected != selected || strings.Contains(view, "subscription-token") {
		t.Fatal("refresh lost a selection, duplicated a subscription or exposed its link")
	}
}

func TestClientStatePreservesProfilesAndStripsCredentials(t *testing.T) {
	state, err := AddClientSubscription("", strings.Replace(testXrayBalance, "Автовыбор", "АВТО", 1), false)
	if err != nil {
		t.Fatal(err)
	}
	view, err := ClientStateView(state)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(state, "test-nl") || strings.Contains(view, "test-nl") {
		t.Fatal("connection credentials must be confined to the stored snapshot")
	}
	var before struct {
		Subscriptions []subscriptionPreview `json:"subscriptions"`
	}
	if err := json.Unmarshal([]byte(view), &before); err != nil {
		t.Fatal(err)
	}
	item := before.Subscriptions[0]
	server := item.Servers[0]
	if item.ID == "" || !server.Balance || server.Name != "АВТО" {
		t.Fatalf("unexpected subscription preview: %+v", item)
	}
	settings := `{"selected":"` + server.ID + `","routing":{"defaultAction":"direct"},"appScope":"only","appPackages":["org.example.app"]}`
	state, err = SaveClientSettings(state, settings, true)
	if err != nil {
		t.Fatal(err)
	}
	view, err = ClientStateView(state)
	if err != nil {
		t.Fatal(err)
	}
	var after struct {
		Subscriptions []subscriptionPreview `json:"subscriptions"`
		Settings      clientSettings        `json:"settings"`
	}
	if err := json.Unmarshal([]byte(view), &after); err != nil {
		t.Fatal(err)
	}
	if after.Subscriptions[0].ID != item.ID || after.Subscriptions[0].Servers[0] != server ||
		after.Settings.Selected != server.ID || after.Settings.AppScope != "only" {
		t.Fatalf("profile or settings changed: %+v", after)
	}
	if _, err := SaveClientSettings(state, `{"routing":{"rules":[{"domains":["999.1.1.1/8"],"action":"direct"}]}}`, true); err == nil {
		t.Fatal("invalid routing settings were accepted")
	}
}
