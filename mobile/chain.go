package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
)

// ProfileChain returns the JSON array of server IDs in connection order,
// beginning at the first VPN server and ending at the selected exit.
// A fallback profile has its own chain and must be resolved independently.
func (r *Router) ProfileChain(profileID string) (string, error) {
	if profileID == "" || strings.TrimSpace(profileID) != profileID {
		return "", errors.New("укажите идентификатор VPN-профиля")
	}
	raw, err := json.Marshal(r.profileChain(profileID))
	return string(raw), err
}

func (r *Router) profileChain(profileID string) []string {
	var chain []string
	for id := profileID; id != ""; id = r.viaProfiles[id] {
		chain = append(chain, id)
	}
	slices.Reverse(chain)
	return chain
}

func validateProfileChains(viaProfiles map[string]string) error {
	for id, via := range viaProfiles {
		if id == "" || via == "" || strings.TrimSpace(id) != id || strings.TrimSpace(via) != via {
			return errors.New("в цепочке VPN нужны идентификаторы обоих профилей")
		}
	}
	const (
		visiting = 1
		visited  = 2
	)
	state := make(map[string]uint8, len(viaProfiles))
	for profile := range viaProfiles {
		var path []string
		for id := profile; id != "" && state[id] != visited; id = viaProfiles[id] {
			if state[id] == visiting {
				return fmt.Errorf("профиль %q образует цикл в цепочке VPN", id)
			}
			state[id] = visiting
			path = append(path, id)
		}
		for _, id := range path {
			state[id] = visited
		}
	}
	return nil
}

func (s clientState) validateGroupChains(via map[string]string) error {
	names := make(map[string]string)
	for _, sub := range s.Subscriptions {
		for _, profile := range sub.Snapshot.Servers {
			names[profile.ID] = profile.Name
		}
	}
	edges := make(map[string][]string, len(via)+len(s.ServerGroups))
	for exit, entry := range via {
		edges[exit] = []string{entry}
	}
	for _, group := range s.ServerGroups {
		names[group.ID] = group.Name
		if via[group.ID] != "" {
			return errors.New("Выберите группу в поле «Через профиль» и отдельный профиль для выхода.")
		}
		edges[group.ID] = group.memberIDs()
	}
	visited := make(map[string]bool)
	stack := make(map[string]int)
	var path []string
	var visit func(string) error
	visit = func(id string) error {
		if visited[id] {
			return nil
		}
		if index, found := stack[id]; found {
			cycle := append(slices.Clone(path[index:]), id)
			for i, id := range cycle {
				if name := names[id]; name != "" {
					cycle[i] = name
				}
			}
			return fmt.Errorf("Цепочка замыкается: %s. Уберите одну связь из этой цепочки.", strings.Join(cycle, " → "))
		}
		stack[id] = len(path)
		path = append(path, id)
		for _, next := range edges[id] {
			if err := visit(next); err != nil {
				return err
			}
		}
		path = path[:len(path)-1]
		delete(stack, id)
		visited[id] = true
		return nil
	}
	starts := make([]string, 0, len(via))
	for id := range via {
		starts = append(starts, id)
	}
	slices.Sort(starts)
	for _, id := range starts {
		if err := visit(id); err != nil {
			return err
		}
	}
	return nil
}

func (s clientState) validateSavedGroupChains() error {
	configs := []json.RawMessage{s.Settings.Routing}
	for _, profile := range s.RoutingProfiles {
		if profile.ID != s.activeRoutingID() {
			configs = append(configs, profile.Routing)
		}
	}
	for _, raw := range configs {
		var config routingConfig
		if len(raw) == 0 {
			continue
		}
		if err := json.Unmarshal(raw, &config); err != nil {
			return err
		}
		if err := s.validateGroupChains(config.ViaProfiles); err != nil {
			return err
		}
	}
	return nil
}
