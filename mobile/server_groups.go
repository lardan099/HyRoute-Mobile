package mobile

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
)

const groupSubscriptionID = "server-groups"

type serverGroup struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Primary []string `json:"primary"`
	Reserve string   `json:"reserve"`
}

func (g serverGroup) memberIDs() []string {
	return append(slices.Clone(g.Primary), g.Reserve)
}

func (s clientState) singleServers() map[string]hysteria.Profile {
	servers := make(map[string]hysteria.Profile)
	for _, sub := range s.Subscriptions {
		for _, profile := range sub.Snapshot.Servers {
			if profile.ID != "" && !profile.Missing && profile.Balance == nil {
				servers[profile.ID] = profile
			}
		}
	}
	return servers
}

func (g serverGroup) preview(servers map[string]hysteria.Profile) serverPreview {
	missing := true
	for _, id := range g.memberIDs() {
		if _, ok := servers[id]; ok {
			missing = false
			break
		}
	}
	return serverPreview{ID: g.ID, Name: g.Name, Protocol: "group", Balance: true, Missing: missing}
}

// ChangeServerGroup creates, edits or deletes a group of individual VPN servers.
// An empty definition requests deletion, otherwise it contains the name and members.
func ChangeServerGroup(raw, id, definition string) (string, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return "", err
	}
	index := slices.IndexFunc(state.ServerGroups, func(group serverGroup) bool { return group.ID == id })
	if id != "" && index < 0 {
		return "", errors.New("группа серверов не найдена")
	}
	if definition == "" {
		if index < 0 {
			return "", errors.New("выберите группу серверов")
		}
		refs, err := state.routingReferences()
		if err != nil {
			return "", err
		}
		if slices.Contains(refs, id) {
			return "", errors.New("сначала замените группу в выбранном профиле и сохранённых правилах")
		}
		state.ServerGroups = slices.Delete(state.ServerGroups, index, index+1)
	} else {
		var group serverGroup
		if err := json.Unmarshal([]byte(definition), &group); err != nil {
			return "", errors.New("не удалось открыть группу серверов")
		}
		group.Name = strings.TrimSpace(group.Name)
		if group.Name == "" || utf8.RuneCountInString(group.Name) > 80 {
			return "", errors.New("введите название группы до 80 символов")
		}
		if len(group.Primary) < 1 || len(group.Primary) > 16 || group.Reserve == "" {
			return "", errors.New("выберите от 1 до 16 основных серверов и один резервный")
		}
		servers := state.singleServers()
		seen := make(map[string]bool)
		for _, member := range group.memberIDs() {
			if servers[member].ID == "" || seen[member] {
				return "", errors.New("выберите разные доступные серверы для группы")
			}
			seen[member] = true
		}
		if index < 0 {
			if len(state.ServerGroups) >= 24 {
				return "", errors.New("достигнут лимит в 24 группы серверов")
			}
			group.ID = "group-" + rand.Text()
			state.ServerGroups = append(state.ServerGroups, group)
		} else {
			group.ID = id
			state.ServerGroups[index] = group
		}
	}
	data, err := json.Marshal(state)
	return string(data), err
}

func (s clientState) validateGroupChains(via map[string]string) error {
	for _, group := range s.ServerGroups {
		for exit, entry := range via {
			if group.ID == exit || group.ID == entry {
				return errors.New("для цепочки выберите отдельные серверы вместо своей группы")
			}
		}
	}
	return nil
}
