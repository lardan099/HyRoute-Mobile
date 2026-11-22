package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

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
