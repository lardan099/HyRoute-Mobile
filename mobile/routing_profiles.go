package mobile

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"strings"
	"unicode/utf8"

	"github.com/lardan099/hyroute-mobile/internal/subscription"
)

const defaultRoutingProfile = "default"
const defaultRoutingProfileName = "Основной"

type routingProfile struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Only inactive profiles need a snapshot. The active rules are stored in settings.
	Routing json.RawMessage `json:"routing,omitempty"`
}

type routingProfileView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	RuleCount int    `json:"ruleCount"`
}

func (s clientState) activeRoutingID() string {
	if s.ActiveRoutingProfile == "" {
		return defaultRoutingProfile
	}
	return s.ActiveRoutingProfile
}

func (s clientState) routingProfiles() []routingProfile {
	if len(s.RoutingProfiles) != 0 {
		return s.RoutingProfiles
	}
	return []routingProfile{{ID: defaultRoutingProfile, Name: defaultRoutingProfileName}}
}

func (s clientState) routingProfileViews() []routingProfileView {
	profiles := s.routingProfiles()
	display := make([]routingProfileView, 0, len(profiles))
	for _, profile := range profiles {
		raw := profile.Routing
		if profile.ID == s.activeRoutingID() {
			raw = s.Settings.Routing
		}
		var config routingConfig
		_ = json.Unmarshal(raw, &config)
		display = append(display, routingProfileView{profile.ID, profile.Name, len(config.Rules)})
	}
	return display
}

// ChangeRoutingProfile copies, switches, renames, or removes a local rules
// profile without changing the default VPN server or Android app scope.
func ChangeRoutingProfile(raw, operation, id, name string) (string, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return "", err
	}
	state.RoutingProfiles = state.routingProfiles()
	active, index := -1, -1
	for i, profile := range state.RoutingProfiles {
		if profile.ID == state.activeRoutingID() {
			active = i
		}
		if profile.ID == id {
			index = i
		}
	}
	if active < 0 {
		return "", errors.New("текущий профиль правил отсутствует")
	}
	if operation != "copy" && index < 0 {
		return "", errors.New("профиль правил больше недоступен")
	}
	if operation == "copy" || operation == "rename" {
		name = subscription.CleanTitle(name)
		if name == "" || utf8.RuneCountInString(name) > 40 {
			return "", errors.New("введите название от 1 до 40 символов")
		}
		for _, profile := range state.RoutingProfiles {
			if strings.EqualFold(profile.Name, name) && (operation == "copy" || profile.ID != id) {
				return "", errors.New("профиль правил с таким названием уже есть")
			}
		}
	}
	switch operation {
	case "copy":
		state.RoutingProfiles[active].Routing = state.Settings.Routing
		id = rand.Text()
		state.RoutingProfiles = append(state.RoutingProfiles, routingProfile{ID: id, Name: name})
		state.ActiveRoutingProfile = id
	case "activate":
		if active == index {
			return raw, nil
		}
		state.RoutingProfiles[active].Routing = state.Settings.Routing
		state.Settings.Routing = state.RoutingProfiles[index].Routing
		state.RoutingProfiles[index].Routing = nil
		state.ActiveRoutingProfile = id
	case "rename":
		state.RoutingProfiles[index].Name = name
	case "delete":
		if id == defaultRoutingProfile || active == index {
			return "", errors.New("сначала переключитесь на другой профиль правил")
		}
		state.RoutingProfiles = append(state.RoutingProfiles[:index], state.RoutingProfiles[index+1:]...)
	default:
		return "", errors.New("неизвестное действие с профилем правил")
	}
	data, err := json.Marshal(state)
	return string(data), err
}
