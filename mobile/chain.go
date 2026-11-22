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
