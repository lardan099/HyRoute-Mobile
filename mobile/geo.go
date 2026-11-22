package mobile

import (
	"context"
	"encoding/json"
	"errors"
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

// UpdateGeo installs the same default geodata as desktop HyRoute.
func UpdateGeo() error {
	geoCatalog.Lock()
	defer geoCatalog.Unlock()
	if geoCatalog.db == nil {
		return errors.New("хранилище баз правил не настроено")
	}
	source, _ := geodata.FindSource(geodata.DefaultSource)
	updater := geodata.Updater{DB: geoCatalog.db}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	_, err := updater.Update(ctx, source, false)
	if err == nil && (geoCatalog.db.Missing(geodata.Site) || geoCatalog.db.Missing(geodata.IP)) {
		return errors.New("скачаны не все базы правил")
	}
	return err
}
