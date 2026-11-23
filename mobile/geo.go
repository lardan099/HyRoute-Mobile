package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/geodata"
	"github.com/lardan099/hyroute-mobile/internal/rules"
)

type geoResolver struct{ db *geodata.DB }

func (g geoResolver) Site(name string) (rules.DomainMatcher, error) {
	matcher, err := g.db.Site(name)
	if errors.Is(err, geodata.ErrNoData) {
		return nil, rules.ErrGeoNoData
	}
	if err != nil {
		return nil, err
	}
	return matcher, nil
}

func (g geoResolver) IP(name string) (rules.IPMatcher, error) {
	matcher, err := g.db.IP(name)
	if errors.Is(err, geodata.ErrNoData) {
		return nil, rules.ErrGeoNoData
	}
	if err != nil {
		return nil, err
	}
	return matcher, nil
}

var geoCatalog struct {
	sync.Mutex
	db *geodata.DB
}

// ConfigureGeo installs the rule database resolver for the app's private directory.
func ConfigureGeo(directory string) {
	geoCatalog.Lock()
	defer geoCatalog.Unlock()
	if geoCatalog.db == nil || geoCatalog.db.Dir != directory {
		geoCatalog.db = &geodata.DB{Dir: directory}
		rules.SetGeo(geoResolver{db: geoCatalog.db})
	}
}

// GeoTags returns the installed geosite and geoip categories.
func GeoTags() (string, error) {
	geoCatalog.Lock()
	defer geoCatalog.Unlock()
	if geoCatalog.db == nil {
		return "", errors.New("хранилище баз правил не настроено")
	}
	tags := make([]string, 0)
	for _, kind := range []geodata.Kind{geodata.Site, geodata.IP} {
		names, err := geoCatalog.db.Names(kind)
		if errors.Is(err, geodata.ErrNoData) {
			continue
		}
		if err != nil {
			return "", err
		}
		for _, name := range names {
			tags = append(tags, kind.Prefix()+":"+name)
		}
	}
	data, err := json.Marshal(tags)
	return string(data), err
}

const geoLocalFile = "file"

type geoSettings struct {
	Site string `json:"site"`
	IP   string `json:"ip"`
}

func geoKind(kind string) (geodata.Kind, error) {
	switch kind {
	case "geosite":
		return geodata.Site, nil
	case "geoip":
		return geodata.IP, nil
	default:
		return 0, errors.New("неизвестный тип базы")
	}
}

// VPNGeodataKinds lists the databases referenced by active VPN rules.
func VPNGeodataKinds(raw string) string {
	refs, _ := vpnGeodataReferences(raw)
	var kinds []string
	for _, ref := range refs {
		if kind := ref.kind.Prefix(); !slices.Contains(kinds, kind) {
			kinds = append(kinds, kind)
		}
	}
	return strings.Join(kinds, "\n")
}

type vpnGeoReference struct {
	kind geodata.Kind
	name string
}

func vpnGeodataReferences(raw string) ([]vpnGeoReference, error) {
	state, err := decodeClientState(raw)
	if err != nil || len(state.Settings.Routing) == 0 {
		return nil, err
	}
	var cfg routingConfig
	if err := json.Unmarshal(state.Settings.Routing, &cfg); err != nil {
		return nil, err
	}
	var refs []vpnGeoReference
	for _, rule := range cfg.Rules {
		if rule.Enabled != nil && !*rule.Enabled {
			continue
		}
		for _, domain := range rule.AllDomains() {
			prefix, name, typed := strings.Cut(strings.ToLower(strings.TrimSpace(domain)), ":")
			if kind, err := geoKind(prefix); typed && err == nil {
				refs = append(refs, vpnGeoReference{kind: kind, name: strings.TrimSpace(name)})
			}
		}
	}
	return refs, nil
}

func (s *geoSettings) source(kind geodata.Kind) *string {
	if kind == geodata.IP {
		return &s.IP
	}
	return &s.Site
}

func readGeoSettings(dir string) (geoSettings, error) {
	var settings geoSettings
	data, err := os.ReadFile(filepath.Join(dir, "mobile-geo.json"))
	if errors.Is(err, os.ErrNotExist) {
		return settings, nil
	}
	if err != nil {
		return settings, err
	}
	return settings, json.Unmarshal(data, &settings)
}

func writeGeoSettings(dir string, settings geoSettings) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(dir, "mobile-geo.*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(settings)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(file.Name(), filepath.Join(dir, "mobile-geo.json"))
}

// GeoSettings returns the current source for each type of database.
func GeoSettings() (string, error) {
	geoCatalog.Lock()
	defer geoCatalog.Unlock()
	if geoCatalog.db == nil {
		return "", errors.New("хранилище баз правил не настроено")
	}
	settings, err := readGeoSettings(geoCatalog.db.Dir)
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(settings)
	return string(data), err
}

// SetGeoSource changes the HTTPS source for one database. An empty source
// restores the default download URL.
func SetGeoSource(kind, address string) error {
	k, err := geoKind(kind)
	if err != nil {
		return err
	}
	address = strings.TrimSpace(address)
	if address != "" {
		u, err := url.Parse(address)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
			return errors.New("укажите ссылку HTTPS на файл базы")
		}
	}
	geoCatalog.Lock()
	defer geoCatalog.Unlock()
	if geoCatalog.db == nil {
		return errors.New("хранилище баз правил не настроено")
	}
	settings, err := readGeoSettings(geoCatalog.db.Dir)
	if err != nil {
		return err
	}
	*settings.source(k) = address
	return writeGeoSettings(geoCatalog.db.Dir, settings)
}

// ImportGeoFile installs and pins one file. Network updates continue for
// the other database, but leave the imported file in place.
func ImportGeoFile(kind, path string) error {
	return ImportGeoFileForState(kind, path, "")
}

func ImportGeoFileForState(kind, path, raw string) error {
	k, err := geoKind(kind)
	if err != nil {
		return err
	}
	geoCatalog.Lock()
	defer geoCatalog.Unlock()
	if geoCatalog.db == nil {
		return errors.New("хранилище баз правил не настроено")
	}
	dir := geoCatalog.db.Dir
	previous, err := readGeoSettings(dir)
	if err != nil {
		return err
	}
	next := previous
	*next.source(k) = geoLocalFile
	if err := writeGeoSettings(dir, next); err != nil {
		return err
	}
	validator, err := geoCategoryValidator(raw, geoCatalog.db)
	if err != nil {
		return errors.Join(err, writeGeoSettings(dir, previous))
	}
	updater := geodata.Updater{DB: geoCatalog.db, Validate: validator}
	if err := updater.InstallFile(k, path); err != nil {
		return errors.Join(err, writeGeoSettings(dir, previous))
	}
	return nil
}

// UpdateGeo refreshes configured network sources on request.
func UpdateGeo() error {
	return UpdateGeoForState("")
}

func UpdateGeoForState(raw string) error { return updateGeo(context.Background(), false, raw) }

// AutoUpdateGeo refreshes installed network sources once daily and retries
// failures after an hour. Selecting a local file opts that database out.
func AutoUpdateGeo() error {
	return AutoUpdateGeoForState("")
}

func AutoUpdateGeoForState(raw string) error { return updateGeo(context.Background(), true, raw) }

func updateGeo(parent context.Context, scheduled bool, raw string) error {
	geoCatalog.Lock()
	defer geoCatalog.Unlock()
	if err := parent.Err(); err != nil {
		return err
	}
	if geoCatalog.db == nil {
		return errors.New("хранилище баз правил не настроено")
	}
	settings, err := readGeoSettings(geoCatalog.db.Dir)
	if err != nil {
		return err
	}
	source, _ := geodata.FindSource(geodata.DefaultSource)
	address := func(configured string, fallback string) string {
		switch configured {
		case geoLocalFile:
			return ""
		case "":
			return fallback
		default:
			return configured
		}
	}
	source.Site = address(settings.Site, source.Site)
	source.IP = address(settings.IP, source.IP)
	validator, err := geoCategoryValidator(raw, geoCatalog.db)
	if err != nil {
		return err
	}
	updater := geodata.Updater{DB: geoCatalog.db, Validate: func(kind geodata.Kind, path string) error {
		if err := geodata.CheckKind(kind, path); err != nil {
			return err
		}
		return validator(kind, path)
	}}
	if scheduled {
		state := updater.State()
		if settings.Site == "" && state.Site == nil && geoCatalog.db.Missing(geodata.Site) {
			source.Site = ""
		}
		if settings.IP == "" && state.IP == nil && geoCatalog.db.Missing(geodata.IP) {
			source.IP = ""
		}
		interval := 24 * time.Hour
		if state.LastError != "" {
			interval = time.Hour
		}
		if time.Since(state.Checked) < interval {
			return nil
		}
	}
	if source.Site == "" && source.IP == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(parent, 3*time.Minute)
	defer cancel()
	if scheduled {
		_, err = updater.UpdateScheduled(ctx, source)
	} else {
		_, err = updater.Update(ctx, source, false)
	}
	return err
}

func geoCategoryValidator(raw string, db *geodata.DB) (func(geodata.Kind, string) error, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return nil, err
	}
	profiles := []json.RawMessage{state.Settings.Routing}
	for _, profile := range state.RoutingProfiles {
		if profile.ID != state.activeRoutingID() {
			profiles = append(profiles, profile.Routing)
		}
	}
	var used [2][]string
	for _, raw := range profiles {
		if len(raw) == 0 {
			continue
		}
		var cfg routingConfig
		if err := json.Unmarshal(raw, &cfg); err != nil {
			return nil, err
		}
		for _, rule := range cfg.Rules {
			for _, domain := range rule.AllDomains() {
				prefix, name, _ := strings.Cut(strings.ToLower(strings.TrimSpace(domain)), ":")
				kind, err := geoKind(prefix)
				name = strings.TrimSpace(name)
				if err != nil || name == "" || slices.Contains(used[kind], name) {
					continue
				}
				if kind == geodata.IP {
					if set, err := db.IP(name); name != "private" && err == nil && set.Len() > 0 {
						used[kind] = append(used[kind], name)
					}
				} else if set, err := db.Site(name); err == nil && set.Len() > 0 {
					used[kind] = append(used[kind], name)
				}
			}
		}
	}
	return func(kind geodata.Kind, path string) error {
		return geodata.CheckCategories(kind, path, used[kind])
	}, nil
}
