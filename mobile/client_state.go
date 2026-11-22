package mobile

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"strings"
)

type savedSubscription struct {
	ID       string               `json:"id"`
	URL      string               `json:"url,omitempty"`
	Snapshot importedSubscription `json:"snapshot"`
}

type clientSettings struct {
	Selected    string          `json:"selected,omitempty"`
	Routing     json.RawMessage `json:"routing,omitempty"`
	AppScope    string          `json:"appScope,omitempty"`
	AppPackages []string        `json:"appPackages,omitempty"`
}

type clientState struct {
	Subscriptions []savedSubscription `json:"subscriptions,omitempty"`
	Settings      clientSettings      `json:"settings"`
}

func decodeClientState(raw string) (clientState, error) {
	var state clientState
	if raw != "" {
		if err := json.Unmarshal([]byte(raw), &state); err != nil {
			return state, errors.New("хранилище приложения повреждено")
		}
	}
	return state, nil
}

// AddClientSubscription returns an updated snapshot for encrypted storage only.
func AddClientSubscription(raw, input string, fromURL bool) (string, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return "", err
	}
	if fromURL {
		input = strings.TrimSpace(input)
		for index, item := range state.Subscriptions {
			if item.URL == input {
				return refreshClientSubscription(state, index)
			}
		}
	}
	imported, err := importInput(input, fromURL)
	if err != nil {
		return "", err
	}
	item := savedSubscription{ID: rand.Text()}
	if err := json.Unmarshal([]byte(imported), &item.Snapshot); err != nil {
		return "", err
	}
	if fromURL {
		item.URL = input
	}
	state.Subscriptions = append(state.Subscriptions, item)
	if state.Settings.Selected == "" {
		for _, server := range item.Snapshot.Servers {
			if server.Missing {
				continue
			}
			if state.Settings.Selected == "" || server.Balance != nil {
				state.Settings.Selected = server.ID
			}
			if server.Balance != nil {
				break
			}
		}
	}
	data, err := json.Marshal(state)
	return string(data), err
}

// RefreshClientSubscription updates the saved URL snapshot while preserving
// IDs referenced by local rules, chains and the selected profile.
func RefreshClientSubscription(raw, subscriptionID string) (string, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return "", err
	}
	for index, item := range state.Subscriptions {
		if item.ID == subscriptionID && item.URL != "" {
			return refreshClientSubscription(state, index)
		}
	}
	return "", errors.New("ссылка подписки недоступна")
}

func refreshClientSubscription(state clientState, index int) (string, error) {
	fresh, err := FetchSubscription(state.Subscriptions[index].URL)
	if err != nil {
		return "", err
	}
	return mergeClientSubscription(state, index, fresh)
}

func mergeClientSubscription(state clientState, index int, fresh string) (string, error) {
	item := &state.Subscriptions[index]
	var cfg routingConfig
	if raw := state.Settings.Routing; len(raw) != 0 {
		if err := json.Unmarshal(raw, &cfg); err != nil {
			return "", err
		}
	}
	references := []string{state.Settings.Selected}
	references = append(references, cfg.DefaultFallback...)
	for _, rule := range cfg.Rules {
		references = append(references, rule.Profile)
		references = append(references, rule.Fallback...)
	}
	for exit, entry := range cfg.ViaProfiles {
		references = append(references, exit, entry)
	}
	ids, err := json.Marshal(references)
	if err != nil {
		return "", err
	}
	previous, err := json.Marshal(item.Snapshot)
	if err != nil {
		return "", err
	}
	merged, err := MergeSubscription(string(previous), fresh, string(ids))
	if err != nil {
		return "", err
	}
	item.Snapshot = importedSubscription{}
	if err := json.Unmarshal([]byte(merged), &item.Snapshot); err != nil {
		return "", err
	}
	data, err := json.Marshal(state)
	return string(data), err
}

// SaveClientSettings validates the routing settings before replacing them.
func SaveClientSettings(raw, settingsJSON string, android bool) (string, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return "", err
	}
	var settings clientSettings
	if err := json.Unmarshal([]byte(settingsJSON), &settings); err != nil {
		return "", err
	}
	if _, err := newRouter(string(settings.Routing), settings.Selected, android); err != nil {
		return "", err
	}
	state.Settings = settings
	data, err := json.Marshal(state)
	return string(data), err
}

// ClientStateView strips subscription links and connection credentials from the
// saved state before exposing it to the application UI.
func ClientStateView(raw string) (string, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return "", err
	}
	view := struct {
		Subscriptions []subscriptionPreview `json:"subscriptions"`
		Settings      clientSettings        `json:"settings"`
	}{Subscriptions: make([]subscriptionPreview, 0, len(state.Subscriptions)), Settings: state.Settings}
	for _, item := range state.Subscriptions {
		preview := previewSubscription(item.ID, item.Snapshot)
		preview.CanRefresh = item.URL != ""
		view.Subscriptions = append(view.Subscriptions, preview)
	}
	data, err := json.Marshal(view)
	return string(data), err
}
