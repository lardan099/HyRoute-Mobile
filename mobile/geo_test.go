package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protowire"
)

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
