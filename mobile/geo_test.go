package mobile

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lardan099/hyroute-mobile/internal/geodata"
	"github.com/lardan099/hyroute-mobile/internal/rules"
	"google.golang.org/protobuf/encoding/protowire"
)

func TestVPNGeodataSnapshotPreservesActiveRules(t *testing.T) {
	source, destination := t.TempDir(), t.TempDir()
	field := func(number protowire.Number, value []byte) []byte {
		return protowire.AppendBytes(protowire.AppendTag(nil, number, protowire.BytesType), value)
	}
	category := func(name string, body []byte) []byte {
		return field(1, append(field(1, []byte(name)), field(2, body)...))
	}
	domain := append(field(2, []byte("exact.example.test")), field(3, field(1, []byte("wanted")))...)
	site := append(category("USED", domain), category("OTHER", field(2, []byte("other.example.test")))...)
	if err := os.WriteFile(filepath.Join(source, "geosite.dat"), site, 0600); err != nil {
		t.Fatal(err)
	}
	ip := append(field(1, []byte{8, 8, 8, 8}), protowire.AppendVarint(protowire.AppendTag(nil, 2, protowire.VarintType), 32)...)
	if err := os.WriteFile(filepath.Join(source, "geoip.dat"), category("USEDIP", ip), 0600); err != nil {
		t.Fatal(err)
	}
	state := `{"subscriptions":[{"snapshot":{"servers":[{"id":"fixture","host":"127.0.0.1","ports":"443","auth":"fixture"}]}}],
	"settings":{"selected":"fixture","routing":{"defaultAction":"tunnel","rules":[
		{"domains":["geosite:used@wanted","geoip:usedip","geoip:private"],"action":"direct"},
		{"domains":["geosite:other"],"action":"block","enabled":false}]}}}`
	payload, err := VPNGeodataSnapshot(state, source)
	if err != nil || len(payload) == 0 || len(payload) > 24<<10 {
		t.Fatalf("unexpected startup package: %d bytes, %v", len(payload), err)
	}
	if err := InstallVPNGeodataSnapshot(payload, destination); err != nil {
		t.Fatal(err)
	}
	db := geodata.DB{Dir: destination}
	names, err := db.Names(geodata.Site)
	if err != nil || len(names) != 1 || names[0] != "used" {
		t.Fatalf("snapshot included unused categories: %v, %v", names, err)
	}
	ConfigureGeo(destination)
	plan, err := NewVPNPlan(state, false)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(destination, "geosite.dat")); err != nil {
		t.Fatal(err)
	}
	subject := rules.Subject{Proto: 6, Dst: netip.MustParseAddrPort("8.8.4.4:443")}
	if got := plan.evaluateFlow(subject, "exact.example.test"); got.Action != rules.Direct {
		t.Fatalf("selected category failed to route directly: %+v", got)
	}
	if got := plan.evaluateFlow(subject, "other.example.test"); got.Action != rules.Tunnel {
		t.Fatalf("inactive category changed routing: %+v", got)
	}
	subject.Dst = netip.MustParseAddrPort("8.8.8.8:443")
	if got := plan.evaluateFlow(subject, ""); got.Action != rules.Direct {
		t.Fatalf("selected GeoIP category failed to route directly: %+v", got)
	}
	subject.Dst = netip.MustParseAddrPort("192.168.1.1:443")
	if got := plan.evaluateFlow(subject, ""); got.Action != rules.Direct {
		t.Fatalf("built-in GeoIP private category is unavailable: %+v", got)
	}
}

func TestVPNGeodataSnapshotRejectsUnexpectedFile(t *testing.T) {
	var data bytes.Buffer
	archive := zip.NewWriter(&data)
	if _, err := archive.Create("../geosite.dat"); err != nil {
		t.Fatal(err)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := InstallVPNGeodataSnapshot(data.Bytes(), t.TempDir()); err == nil {
		t.Fatal("accepted a file outside the snapshot directory")
	}
}

func TestVPNGeodataKinds(t *testing.T) {
	state := `{"settings":{"routing":{"rules":[
		{"domain":{"pattern":"GEOSITE:youtube"},"action":"tunnel"},
		{"domains":["geoip:telegram","geosite:telegram"],"action":"direct"},
		{"domains":["geoip:ru"],"action":"block","enabled":false},
		{"domains":["example.org"],"action":"direct"}]}}}`
	if got := VPNGeodataKinds(state); got != "geosite\ngeoip" {
		t.Fatalf("active geodata kinds = %q", got)
	}
	onlyDisabled := `{"settings":{"routing":{"rules":[{"domains":["geosite:youtube"],"action":"direct","enabled":false}]}}}`
	if got := VPNGeodataKinds(onlyDisabled); got != "" {
		t.Fatalf("disabled rule requested geodata: %q", got)
	}
	bareLabel := `{"settings":{"routing":{"rules":[{"domains":["geoip"],"action":"direct"}]}}}`
	if got := VPNGeodataKinds(bareLabel); got != "" {
		t.Fatalf("plain domain label requested geodata: %q", got)
	}
}

func TestCustomGeoFilesAreValidatedAndPinned(t *testing.T) {
	db := t.TempDir()
	input := t.TempDir()
	ConfigureGeo(db)
	field := func(number protowire.Number, value []byte) []byte {
		return protowire.AppendBytes(protowire.AppendTag(nil, number, protowire.BytesType), value)
	}
	category := func(name string, entry []byte) []byte {
		return field(1, append(field(1, []byte(name)), field(2, entry)...))
	}
	site := filepath.Join(input, "domains.dat")
	ip := filepath.Join(input, "networks.dat")
	if err := os.WriteFile(site, category("APP", field(2, []byte("app.example.test"))), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ip, category("NETWORK", field(1, []byte{192, 0, 2, 1})), 0600); err != nil {
		t.Fatal(err)
	}
	if err := SetGeoSource("geosite", "http://example.test/geosite.dat"); err == nil {
		t.Fatal("insecure custom source accepted")
	}
	if err := SetGeoSource("geosite", "https://example.test/geosite.dat?revision=1"); err != nil {
		t.Fatal(err)
	}
	for _, file := range []struct{ kind, path string }{{"geosite", site}, {"geoip", ip}} {
		if err := ImportGeoFile(file.kind, file.path); err != nil {
			t.Fatal(err)
		}
	}
	if err := ImportGeoFile("geosite", ip); err == nil {
		t.Fatal("GeoIP file accepted as GeoSite")
	}
	if err := ImportGeoFile("geoip", site); err == nil {
		t.Fatal("GeoSite file accepted as GeoIP")
	}
	replacement := filepath.Join(input, "replacement.dat")
	if err := os.WriteFile(replacement, category("OTHER", field(2, []byte("other.example.test"))), 0600); err != nil {
		t.Fatal(err)
	}
	state := `{"settings":{"routing":{"rules":[]}},"routingProfiles":[{"id":"stored","name":"Stored",
		"routing":{"rules":[{"domains":["geosite:app"],"action":"direct"}]}}]}`
	if err := ImportGeoFileForState("geosite", replacement, state); err == nil || !strings.Contains(err.Error(), "geosite:app") {
		t.Fatalf("replacement should preserve the category referenced by dormant rules: %v", err)
	}
	raw, err := GeoSettings()
	var settings geoSettings
	if err != nil || json.Unmarshal([]byte(raw), &settings) != nil || settings.Site != geoLocalFile || settings.IP != geoLocalFile {
		t.Fatalf("file choices were not retained: %q, %v", raw, err)
	}
	if err := AutoUpdateGeo(); err != nil {
		t.Fatal(err)
	}
	tags, err := GeoTags()
	if err != nil || !strings.Contains(tags, "geosite:app") || !strings.Contains(tags, "geoip:network") {
		t.Fatalf("automatic update changed the imported files: %q, %v", tags, err)
	}
}
