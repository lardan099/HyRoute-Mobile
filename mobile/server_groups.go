package mobile

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/vless"
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

type groupCandidate struct {
	profile hysteria.Profile
	node    *vless.Node
}

func (s clientState) groupCandidates() (map[string]groupCandidate, []string) {
	servers := make(map[string]groupCandidate)
	var order []string
	add := func(candidate groupCandidate) {
		id := candidate.profile.ID
		if _, exists := servers[id]; !exists {
			servers[id] = candidate
			order = append(order, id)
		}
	}
	for _, sub := range s.Subscriptions {
		for _, profile := range sub.Snapshot.Servers {
			if profile.ID == "" || profile.Missing {
				continue
			}
			if profile.Balance == nil {
				add(groupCandidate{profile: profile})
				continue
			}
			for _, node := range profile.Balance.Nodes {
				identity := node
				identity.Settings.ID = ""
				wire, _ := json.Marshal(identity)
				key := sha256.Sum256(append([]byte(profile.ID+"\x00"), wire...))
				add(groupCandidate{node: &node, profile: hysteria.Profile{
					ID: fmt.Sprintf("node-%x", key[:16]), Name: fmt.Sprintf("%s · %s:%d", profile.Name, node.Host, node.Port),
					Host: node.Host, Ports: fmt.Sprint(node.Port), Protocol: hysteria.ProtoVLESS, VLESS: node.Settings,
				}})
			}
		}
	}
	return servers, order
}

func (g serverGroup) preview(servers map[string]groupCandidate) serverPreview {
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
		servers, _ := state.groupCandidates()
		seen := make(map[string]bool)
		for _, member := range group.memberIDs() {
			if servers[member].profile.ID == "" || seen[member] {
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
		if err := state.validateSavedGroupChains(); err != nil {
			return "", err
		}
	}
	data, err := json.Marshal(state)
	return string(data), err
}
