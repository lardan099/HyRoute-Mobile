package subscription

import (
	"encoding/base64"
	"net/http"
	"strings"
	"testing"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
)

func TestParseSubscriptionResponses(t *testing.T) {
	const body = "hy2://fixture@one.example:443#Name with spaces vmess://ignored\nhy2://fixture@two.example:443"
	for _, value := range []string{body, base64.RawURLEncoding.EncodeToString([]byte(body))} {
		got, err := Parse([]byte(value))
		if err != nil || len(got.Profiles) != 2 || got.Profiles[0].Name != "Name with spaces" ||
			got.Profiles[1].Name != "two.example" || got.IgnoredTotal() != 1 ||
			got.Base64 != (value != body) {
			t.Fatalf("failed to parse a mixed share list: %v", err)
		}
	}
	for _, test := range []struct{ input, message string }{
		{"", "подписка пустая"},
		{"<!doctype html><html>Sign in</html>", "веб-страницу"},
		{`{"empty":true}`, "JSON без серверов"},
		{"hy2://fixture@127.0.0.1:1#Renew%20subscription", "Renew subscription"},
		{"vmess://unsupported", "другие протоколы"},
		{"hy2://", "не разобран"},
		{"Please renew the subscription", "ответил текстом"},
		{"no links\non multiple lines", "нет ссылок"},
	} {
		if _, err := Parse([]byte(test.input)); err == nil || !strings.Contains(err.Error(), test.message) {
			t.Errorf("want %q, got %v", test.message, err)
		}
	}
}

func TestPanelMetadataNormalizesAndRejectsUnsafeInput(t *testing.T) {
	headers := http.Header{}
	headers.Set("Profile-Title", "base64:"+base64.StdEncoding.EncodeToString([]byte(" Название\t\u202eпанели ")))
	headers.Set("Subscription-Userinfo", "upload=-1; upload=5; upload=8,download=8.9;total=NaN;expire=1790000000000")
	headers.Set("Profile-Update-Interval", " 12 ")
	headers.Set("Support-Url", "https://example.test/support")
	expected := PanelInfo{Title: "Название панели", UserInfo: "upload=5; download=8; expire=1790000000",
		UpdateHours: 12, Support: "https://example.test/support"}
	if got := ReadPanelHeaders(headers).Clean(); got != expected {
		t.Fatalf("unexpected panel metadata: %+v", got)
	}
	for _, unsafe := range []string{"https://user:pass@example.test", "javascript:alert(1)",
		"https://example.test/space here", "https://example.test/line\nbreak", strings.Repeat("a", MaxLinkLen+1)} {
		if SafeLink(unsafe) != "" {
			t.Error("accepted an unsafe panel support link")
		}
	}
	if NormalizeUserInfo("expire=253402300799; total=Infinity; upload=-1") != "" ||
		NormalizeUserInfo(strings.Repeat("a", MaxInfoHeader+1)) != "" || ParseUpdateHours("9000") != 0 {
		t.Fatal("accepted invalid panel metadata")
	}
}

func TestMergeKeepsLocalProfileAndReferencedMissingServer(t *testing.T) {
	const source = "sub:demo"
	previous := []hysteria.Profile{
		{ID: "local", Host: "local.example", Ports: "443", Auth: "fixture"},
		{ID: "kept", Source: source, Host: "old.example", Ports: "443", Auth: "old", PinServerIP: true},
		{ID: "missing", Source: source, Host: "gone.example", Ports: "443", Auth: "fixture"},
		{ID: "removed", Source: source, Host: "remove.example", Ports: "443", Auth: "fixture"},
	}
	rotated := hysteria.Profile{Name: "Renamed", Host: "old.example", Ports: "443", Auth: "updated"}
	newServer := hysteria.Profile{Host: "new.example", Ports: "443", Auth: "fixture"}
	merged, counts := Merge(previous, source, []hysteria.Profile{rotated, rotated, newServer},
		func(id string) bool { return id == "missing" }, func() string { return "new" })
	if counts != (MergeStats{Updated: 1, Added: 1, MissingKept: 1, Removed: 1}) || len(merged) != 4 {
		t.Fatalf("unexpected merge counts: %+v", counts)
	}
	if merged[0].ID != "local" || merged[1].ID != "kept" || !merged[1].PinServerIP ||
		merged[1].Auth != "updated" || merged[2].ID != "new" ||
		merged[3].ID != "missing" || !merged[3].Missing {
		t.Fatal("merge discarded local settings, identity, or a rule target")
	}
	if !SameServers([]hysteria.Profile{rotated, newServer}, []hysteria.Profile{newServer, rotated, rotated}) ||
		SameServers([]hysteria.Profile{rotated}, []hysteria.Profile{newServer}) {
		t.Fatal("unexpected connection identity comparison")
	}
}

// A subscription of thousands keeps its first maxSubServers, with a
// warning: each server is a profile merged and sealed on every update.
func TestSubscriptionServerCap(t *testing.T) {
	l := capServers(Links{Profiles: make([]hysteria.Profile, maxSubServers+5)})
	if len(l.Profiles) != maxSubServers || len(l.Warnings) != 1 {
		t.Fatalf("%d servers, %q", len(l.Profiles), l.Warnings)
	}
	if l := capServers(Links{Profiles: make([]hysteria.Profile, 3)}); len(l.Profiles) != 3 || len(l.Warnings) != 0 {
		t.Fatalf("%d servers, %q", len(l.Profiles), l.Warnings)
	}
}
