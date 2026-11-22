package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestAutomaticSubscriptionRefreshPreservesFailuresAndLocalInputs(t *testing.T) {
	const server = "vless://test-user@regular.example:443?security=tls#Regular"
	raw, err := AddClientSubscription("", server, false)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeClientState(raw)
	if err != nil {
		t.Fatal(err)
	}
	local := state.Subscriptions[0]
	now := time.Now().Truncate(time.Second)
	success := local
	success.ID, success.URL = "renewed", "https://example.test/renewed"
	failure := local
	failure.ID, failure.URL = "failed", "https://example.test/failed"
	recent := local
	recent.ID, recent.URL, recent.RefreshedAt = "fresh", "https://example.test/fresh", now.Unix()
	state.Subscriptions = []savedSubscription{local, success, failure, recent}
	fresh, err := ImportSubscription([]byte(server + "\n" + strings.ReplaceAll(server, "regular.example", "new.example")))
	if err != nil {
		t.Fatal(err)
	}
	var requested []string
	fetch := func(_ context.Context, address string) (string, error) {
		requested = append(requested, address)
		if address == success.URL {
			return fresh, nil
		}
		return "", errors.New("unavailable")
	}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	updated, err := autoRefreshSubscriptions(context.Background(), string(data), now, fetch)
	if err != nil {
		t.Fatal(err)
	}
	result, err := decodeClientState(updated)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(requested, []string{success.URL, failure.URL}) {
		t.Fatalf("updated wrong subscriptions: %v", requested)
	}
	if len(result.Subscriptions[1].Snapshot.Servers) != 2 || result.Subscriptions[1].RefreshedAt != now.Unix() {
		t.Fatal("successful refresh did not update the snapshot and timestamp")
	}
	if !reflect.DeepEqual(result.Subscriptions[2].Snapshot, failure.Snapshot) || result.Subscriptions[2].AttemptedAt != now.Unix() {
		t.Fatal("failed refresh must retain the old snapshot and save a retry timestamp")
	}
	requested = nil
	if current, err := autoRefreshSubscriptions(context.Background(), updated, now.Add(5*time.Minute), fetch); err != nil || current != updated || len(requested) != 0 {
		t.Fatalf("subscriptions were retried early: %v, %v", requested, err)
	}
	if _, err := autoRefreshSubscriptions(context.Background(), updated, now.Add(time.Hour), fetch); err != nil ||
		!reflect.DeepEqual(requested, []string{failure.URL}) {
		t.Fatalf("failed subscription did not become due: %v, %v", requested, err)
	}
}

func TestSubscriptionCardShowsUsageAndPersistsFailedAttempt(t *testing.T) {
	const server = "vless://test-user@regular.example:443?security=tls#Regular"
	raw, err := AddClientSubscription("", server, false)
	if err != nil {
		t.Fatal(err)
	}
	state, err := decodeClientState(raw)
	if err != nil {
		t.Fatal(err)
	}
	old := state.Subscriptions[0]
	now := time.Unix(1795400000, 0)
	state.Subscriptions[0].URL = "https://example.test/private-token"
	state.Subscriptions[0].RefreshedAt = now.Unix()
	state.Subscriptions[0].Snapshot.UserInfo = "upload=2; download=3; total=10; expire=1893456000"
	updated, err := attemptClientSubscriptionRefresh(state, 0, now, func(string) (string, error) {
		return "", errors.New("connection failed")
	})
	if err != nil {
		t.Fatal(err)
	}
	view, err := ClientStateView(updated)
	if err != nil {
		t.Fatal(err)
	}
	var got struct{ Subscriptions []subscriptionPreview }
	if err := json.Unmarshal([]byte(view), &got); err != nil {
		t.Fatal(err)
	}
	item := got.Subscriptions[0]
	if !item.RefreshFailed || item.RefreshedAt != now.Unix() || item.AttemptedAt != now.Unix() ||
		item.UsedBytes == nil || *item.UsedBytes != 5 || item.LimitBytes == nil || *item.LimitBytes != 10 ||
		item.ExpiresAt == nil || *item.ExpiresAt != 1893456000 || item.Servers[0].ID != old.Snapshot.Servers[0].ID {
		t.Fatalf("incorrect subscription summary: %+v", item)
	}
	if strings.Contains(view, "private-token") || strings.Contains(view, "test-user") {
		t.Fatal("subscription details exposed credentials")
	}
}

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
