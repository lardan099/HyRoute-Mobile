package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"slices"
	"strings"

	"github.com/lardan099/hyroute-mobile/internal/rules"
)

// Router evaluates one immutable snapshot of local Hyroute rules.
type Router struct {
	rules       *rules.Set
	appPackages []string
	viaProfiles map[string]string
}

// ViaProfiles maps an exit profile to its upstream VPN profile. Adapters
// must open every hop in order. If a hop fails, use the complete chain of a
// configured fallback, or refuse the flow.
type routingConfig struct {
	rules.Config
	ViaProfiles map[string]string `json:"viaProfiles,omitempty"`
}

// NewRouter compiles local Hyroute rules. An omitted default action blocks
// unmatched traffic. A tunnel rule can use the selected server by omitting its
// profile field.
func NewRouter(localRulesJSON, selectedServerID string) (*Router, error) {
	return newRouter(localRulesJSON, selectedServerID, false)
}

// NewAndroidRouter also accepts rules whose application conditions are exact
// Android package IDs. The VPN service must supply the owner of each flow.
func NewAndroidRouter(localRulesJSON, selectedServerID string) (*Router, error) {
	return newRouter(localRulesJSON, selectedServerID, true)
}

func newRouter(localRulesJSON, selectedServerID string, android bool) (*Router, error) {
	cfg := routingConfig{Config: rules.Config{DefaultAction: rules.Block}}
	if err := json.Unmarshal([]byte(localRulesJSON), &cfg); err != nil {
		return nil, fmt.Errorf("локальные правила: %w", err)
	}
	var packages []string
	for i, rule := range cfg.Rules {
		if rule.Enabled != nil && !*rule.Enabled {
			continue
		}
		for _, app := range rule.AllApps() {
			if !android {
				return nil, fmt.Errorf("правило %d: условия по приложениям недоступны", i+1)
			}
			if !strings.EqualFold(app.Kind, "package") {
				return nil, fmt.Errorf("правило %d: требуется идентификатор пакета Android", i+1)
			}
			packages = append(packages, strings.TrimSpace(app.Pattern))
		}
	}
	if err := validateProfileChains(cfg.ViaProfiles); err != nil {
		return nil, err
	}
	set, err := rules.Compile(cfg.Config)
	if err != nil {
		return nil, err
	}
	if len(set.Warnings) > 0 {
		return nil, fmt.Errorf("локальные правила: %s", set.Warnings[0])
	}
	set.Main = selectedServerID
	slices.Sort(packages)
	return &Router{rules: set, appPackages: slices.Compact(packages), viaProfiles: cfg.ViaProfiles}, nil
}

// AndroidPackages returns the configured Android package IDs, one per line.
// The VPN service can resolve those packages without enumerating installed apps.
func (r *Router) AndroidPackages() string {
	return strings.Join(r.appPackages, "\n")
}

type routeDecision struct {
	Action      string   `json:"action,omitempty"`
	ServerID    string   `json:"serverId,omitempty"`
	Fallback    []string `json:"fallback,omitempty"`
	Chain       []string `json:"chain,omitempty"`
	Rule        string   `json:"rule,omitempty"`
	RuleID      string   `json:"ruleId,omitempty"`
	NeedsDomain bool     `json:"needsDomain,omitempty"`
}

// Decide evaluates a TCP or UDP destination after domain detection. Supply
// the known domain, or an empty string when no domain is known.
func (r *Router) Decide(destination, protocol, domain string) (string, error) {
	return r.DecideForApp(destination, protocol, domain, "", false)
}

// DecideForApp evaluates a flow with its Android owner. An empty package with
// ownerKnown means Android identified an app outside the configured rules.
// If the owner is unknown and package rules are active, the flow must be refused.
func (r *Router) DecideForApp(destination, protocol, domain, appPackage string, ownerKnown bool) (string, error) {
	subject, err := r.flowSubject(destination, protocol, appPackage, ownerKnown)
	if err != nil {
		return "", err
	}
	if domain == "" {
		return r.encodeDecision(r.rules.EvaluateNoDomain(subject))
	}
	return r.encodeDecision(r.rules.EvaluateDomain(subject, domain, rules.SrcNone))
}

// DecideWithDNS checks the cached DNS names before the tunnel has an exact
// domain. dnsSitesJSON contains groups of names, one group per DNS alias
// chain. A needsDomain result asks the caller to look for a reliable domain
// before forwarding the connection.
func (r *Router) DecideWithDNS(destination, protocol, dnsSitesJSON string) (string, error) {
	return r.DecideForAppWithDNS(destination, protocol, dnsSitesJSON, "", false)
}

// DecideForAppWithDNS evaluates cached DNS names with the Android flow owner.
func (r *Router) DecideForAppWithDNS(destination, protocol, dnsSitesJSON, appPackage string, ownerKnown bool) (string, error) {
	subject, err := r.flowSubject(destination, protocol, appPackage, ownerKnown)
	if err != nil {
		return "", err
	}
	var sites [][]string
	if err := json.Unmarshal([]byte(dnsSitesJSON), &sites); err != nil {
		return "", errors.New("ожидался список групп DNS-имён")
	}
	return r.encodeDecision(r.rules.EvaluateSites(subject, sites))
}

func (r *Router) flowSubject(destination, protocol, appPackage string, ownerKnown bool) (rules.Subject, error) {
	if len(r.appPackages) > 0 && !ownerKnown {
		return rules.Subject{}, errors.New("не удалось определить приложение для маршрутизации")
	}
	if appPackage != "" && (!ownerKnown || !rules.ValidAppPackage(appPackage)) {
		return rules.Subject{}, errors.New("неверный идентификатор пакета Android")
	}
	addr, err := netip.ParseAddrPort(destination)
	if err != nil || addr.Port() == 0 {
		return rules.Subject{}, errors.New("укажите IP-адрес и порт назначения")
	}
	subject := rules.Subject{AppPackage: appPackage, Dst: netip.AddrPortFrom(addr.Addr().Unmap(), addr.Port())}
	switch protocol {
	case "tcp":
		subject.Proto = 6
	case "udp":
		subject.Proto = 17
	default:
		return rules.Subject{}, errors.New("протокол назначения должен быть tcp или udp")
	}
	return subject, nil
}

func (r *Router) encodeDecision(result rules.Result) (string, error) {
	if result.NeedsDomain {
		raw, err := json.Marshal(routeDecision{NeedsDomain: true})
		return string(raw), err
	}
	var chain []string
	if result.Action == rules.Tunnel {
		if result.Profile == "" {
			return "", errors.New("для маршрута через VPN выберите сервер")
		}
		if r.viaProfiles[result.Profile] != "" {
			chain = r.profileChain(result.Profile)
		}
	}
	raw, err := json.Marshal(routeDecision{
		Action:   result.Action.String(),
		ServerID: result.Profile,
		Fallback: result.Fallback,
		Chain:    chain,
		Rule:     result.Rule,
		RuleID:   result.RuleID,
	})
	return string(raw), err
}
