package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hy2uri"
	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/rules"
	"github.com/lardan099/hyroute-mobile/internal/vless"
)

const vpnDNS = "1.1.1.1"

const (
	blockTag  = "hyroute-block"
	directTag = "hyroute-direct"
)

var (
	errVPNState       = errors.New("не удалось открыть настройки VPN")
	errVPNProfile     = errors.New("выберите доступный VPN-профиль")
	errVPNRules       = errors.New("не удалось применить локальные правила")
	errVPNReference   = errors.New("правило или цепочка ссылается на недоступный VPN-профиль")
	errVPNUnsupported = errors.New("неподдерживаемая настройка VPN-профиля")
)

// IOSVPNPlanResult carries a plan or a fixed diagnostic identifier. The
// extension can report the latter even when it cannot write a shared journal.
type IOSVPNPlanResult struct {
	plan          *VPNPlan
	issue         string
	geoCategories string
}

func InspectIOSVPNPlan(raw string) *IOSVPNPlanResult {
	plan, err := NewVPNPlan(raw, false)
	result := &IOSVPNPlanResult{plan: plan}
	switch {
	case err == nil:
	case errors.Is(err, errVPNState):
		result.issue = "state"
	case errors.Is(err, errVPNProfile):
		result.issue = "profile"
	case errors.Is(err, errVPNRules):
		result.issue = "rules"
	case errors.Is(err, errVPNGeodata):
		result.issue = "geo"
		var pending *unavailableGeoError
		if errors.As(err, &pending) {
			categories, marshalErr := json.Marshal(pending.categories)
			if marshalErr == nil {
				result.geoCategories = string(categories)
			}
		}
	case errors.Is(err, errVPNReference):
		result.issue = "reference"
	case errors.Is(err, errVPNUnsupported):
		result.issue = "unsupported"
	default:
		result.issue = "configuration"
	}
	return result
}

func (r *IOSVPNPlanResult) Plan() *VPNPlan        { return r.plan }
func (r *IOSVPNPlanResult) Issue() string         { return r.issue }
func (r *IOSVPNPlanResult) GeoCategories() string { return r.geoCategories }

type vpnProfile struct {
	profile hysteria.Profile
	tag     string
	group   []groupMember
}

type groupMember struct {
	groupCandidate
	reserve bool
}

// VPNPlan is an immutable snapshot of the selected profiles and local rules.
type VPNPlan struct {
	router   *Router
	profiles []vpnProfile
	tags     map[string]string
	selected string
	appScope string
	packages []string
	android  bool
	splitDNS *splitDNSSettings
}

// NewVPNPlan validates the saved selection, rules and app scope before a VPN
// interface is established. raw is the private app snapshot, not a UI preview.
func NewVPNPlan(raw string, android bool) (*VPNPlan, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return nil, errVPNState
	}
	settings := state.Settings
	if err := settings.SplitDNS.normalize(); err != nil {
		return nil, errVPNRules
	}
	cfg := routingConfig{Config: rules.Config{DefaultAction: rules.Tunnel}}
	if len(settings.Routing) > 0 {
		if err := json.Unmarshal(settings.Routing, &cfg); err != nil {
			return nil, errVPNRules
		}
	}
	all := make(map[string]hysteria.Profile)
	groups := make(map[string]serverGroup)
	var first, firstGroup string
	for _, item := range state.Subscriptions {
		for _, profile := range item.Snapshot.Servers {
			if profile.Missing || profile.ID == "" {
				continue
			}
			all[profile.ID] = profile
			if first == "" {
				first = profile.ID
			}
			if firstGroup == "" && profile.Balance != nil {
				firstGroup = profile.ID
			}
		}
	}
	singles, _ := state.groupCandidates()
	for _, group := range state.ServerGroups {
		if group.preview(singles).Missing {
			continue
		}
		groups[group.ID] = group
		all[group.ID] = hysteria.Profile{ID: group.ID, Name: group.Name}
		if firstGroup == "" {
			firstGroup = group.ID
		}
	}
	if all[settings.Selected].ID == "" {
		// The apps display the first available group, then the first server, when
		// the saved selection disappears during a subscription refresh.
		settings.Selected = firstGroup
		if settings.Selected == "" {
			settings.Selected = first
		}
	}
	if all[settings.Selected].ID == "" {
		return nil, errVPNProfile
	}
	if err := state.validateGroupChains(cfg.ViaProfiles); err != nil {
		return nil, errVPNRules
	}
	rawRules, err := json.Marshal(cfg)
	if err != nil {
		return nil, err
	}
	router, err := newRouter(string(rawRules), settings.Selected, android)
	if err != nil {
		if errors.Is(err, errVPNGeodata) {
			return nil, err
		}
		return nil, errVPNRules
	}
	plan := &VPNPlan{router: router, tags: make(map[string]string), selected: settings.Selected, android: android, splitDNS: settings.SplitDNS}
	if android {
		plan.appScope = settings.AppScope
		if plan.appScope == "" {
			plan.appScope = "all"
		}
		if plan.appScope != "all" {
			if (plan.appScope != "only" && plan.appScope != "except") || len(settings.AppPackages) == 0 {
				return nil, errors.New("выберите приложения для VPN")
			}
			for _, id := range settings.AppPackages {
				if !rules.ValidAppPackage(id) {
					return nil, errors.New("некорректный список приложений")
				}
			}
			plan.packages = settings.AppPackages
		}
	}
	var add func(string) error
	add = func(id string) error {
		if id == "" || plan.tags[id] != "" {
			return nil
		}
		profile, ok := all[id]
		if !ok {
			return errVPNReference
		}
		if upstream := cfg.ViaProfiles[id]; upstream != "" {
			if err := add(upstream); err != nil {
				return err
			}
		}
		target := vpnProfile{profile: profile}
		if group, ok := groups[id]; ok {
			for _, memberID := range group.memberIDs() {
				member, ok := singles[memberID]
				if !ok || member.profile.Validate() != nil {
					continue
				}
				if err := add(cfg.ViaProfiles[memberID]); err != nil {
					continue
				}
				target.group = append(target.group, groupMember{groupCandidate: member, reserve: memberID == group.Reserve})
			}
			if len(target.group) == 0 {
				return errVPNUnsupported
			}
		} else if err := profile.Validate(); err != nil {
			return errVPNUnsupported
		}
		target.tag = fmt.Sprintf("hyroute-profile-%d", len(plan.profiles))
		plan.tags[id] = target.tag
		plan.profiles = append(plan.profiles, target)
		return nil
	}
	if err := add(settings.Selected); err != nil {
		return nil, err
	}
	for _, rule := range cfg.Rules {
		if rule.Action == rules.Tunnel && (rule.Enabled == nil || *rule.Enabled) {
			if err := add(rule.Profile); err != nil {
				return nil, err
			}
		}
	}
	return plan, nil
}

func (p *VPNPlan) AppScope() string     { return p.appScope }
func (p *VPNPlan) AppPackages() string  { return strings.Join(p.packages, "\n") }
func (p *VPNPlan) RulePackages() string { return p.router.AndroidPackages() }
func (p *VPNPlan) DNSServer() string    { return vpnDNS }

type vpnConfiguration struct {
	plan      *VPNPlan
	xray      map[string]any
	balancers map[string]bool
	labels    map[string]string
	traffic   *trafficJournal
}

func (p *VPNPlan) configuration(ctx context.Context, tunnel bool, resolve func(context.Context, string) netip.Addr) (*vpnConfiguration, error) {
	outbounds := []any{
		map[string]any{"tag": blockTag, "protocol": "blackhole"},
		map[string]any{"tag": directTag, "protocol": "freedom"},
	}
	if p.splitDNS != nil {
		outbounds = append(outbounds, map[string]any{"tag": splitDNSTag, "protocol": "blackhole"})
	}
	var prefixes []string
	var balances, routeRules []any
	var observation *vless.Balance
	balancers := make(map[string]bool)
	labels := map[string]string{directTag: "Напрямую", blockTag: "Блокировка", splitDNSTag: "Раздельный DNS"}
	resolved := make(map[string]netip.Addr)
	resolveOnce := func(host string) netip.Addr {
		if ip, ok := resolved[host]; ok {
			return ip
		}
		ip := resolve(ctx, host)
		resolved[host] = ip
		return ip
	}
	for _, target := range p.profiles {
		profile := target.profile
		labels[target.tag] = journalProfileName(profile)
		upstream := p.tags[p.router.viaProfiles[profile.ID]]
		if profile.Balance == nil && len(target.group) == 0 {
			ip := resolveOnce(profile.Host)
			if !ip.IsValid() {
				return nil, errors.New("не удалось найти адрес VPN-сервера")
			}
			out, err := profileOutbound(profile, ip, target.tag)
			if err != nil {
				return nil, errors.New("не удалось подготовить VPN-профиль")
			}
			setDialerProxy(out, upstream)
			outbounds = append(outbounds, out)
			continue
		}
		prefix := target.tag + "-node-"
		tag := target.tag + "-balancer"
		var balance vless.Balance
		if len(target.group) > 0 {
			nodes, config, err := p.groupOutbounds(target, prefix, tag, resolveOnce, labels)
			if err != nil {
				return nil, err
			}
			outbounds = append(outbounds, nodes...)
			balances = append(balances, config)
		} else {
			balance = *profile.Balance
			ips := make([]netip.Addr, len(balance.Nodes))
			for i, node := range balance.Nodes {
				ips[i] = resolveOnce(node.Host)
				labels[prefix+strconv.Itoa(i)] = fmt.Sprintf("%s · %s", journalProfileName(profile), net.JoinHostPort(node.Host, strconv.Itoa(node.Port)))
			}
			nodes, config, err := vless.BalanceOutbounds(balance, ips, prefix, tag)
			if err != nil {
				return nil, errors.New("не удалось подготовить узлы Автовыбора")
			}
			if config["fallbackTag"] == nil {
				config["fallbackTag"] = blockTag
			}
			for _, node := range nodes {
				setDialerProxy(node.(map[string]any), upstream)
			}
			outbounds = append(outbounds, nodes...)
			balances = append(balances, config)
		}
		outbounds = append(outbounds, map[string]any{
			"tag": target.tag, "protocol": "loopback", "settings": map[string]any{"inboundTag": tag},
		})
		prefixes = append(prefixes, prefix)
		routeRules = append(routeRules, map[string]any{"type": "field", "inboundTag": []string{tag}, "balancerTag": tag})
		balancers[tag] = true
		if observation == nil || target.profile.ID == p.selected {
			observation = &balance
		}
	}
	config := map[string]any{
		"log":       map[string]any{"loglevel": "none", "access": "none", "dnsLog": false},
		"outbounds": outbounds,
		"routing":   map[string]any{"rules": routeRules, "balancers": balances},
	}
	if tunnel {
		config["inbounds"] = []any{map[string]any{
			"tag": "hyroute-tun", "protocol": "tun", "settings": map[string]any{"name": "hyroute", "MTU": 1400},
			"sniffing": map[string]any{"enabled": true, "routeOnly": true, "destOverride": []string{"http", "tls", "quic"}},
		}}
	}
	if observation != nil {
		config["burstObservatory"] = observation.Observatory(prefixes)
	}
	prepared := &vpnConfiguration{plan: p, xray: config, balancers: balancers, labels: labels}
	if !p.android {
		prepared.traffic = new(trafficJournal)
	}
	return prepared, nil
}

func (p *VPNPlan) groupOutbounds(target vpnProfile, prefix, tag string, resolve func(string) netip.Addr, labels map[string]string) ([]any, map[string]any, error) {
	var outbounds []any
	fallback := blockTag
	for i, member := range target.group {
		ip := resolve(member.profile.Host)
		if !ip.IsValid() {
			continue
		}
		memberTag := fmt.Sprintf("%s%d", prefix, i)
		if member.reserve {
			memberTag = target.tag + "-reserve"
		}
		var out map[string]any
		var err error
		if member.node != nil {
			out, err = member.node.Outbound(ip, memberTag)
		} else {
			out, err = profileOutbound(member.profile, ip, memberTag)
		}
		if err != nil {
			continue
		}
		setDialerProxy(out, p.tags[p.router.viaProfiles[member.profile.ID]])
		outbounds = append(outbounds, out)
		labels[memberTag] = journalProfileName(target.profile) + " · " + journalProfileName(member.profile)
		if member.reserve {
			fallback = memberTag
			labels[memberTag] += " (резерв)"
		}
	}
	if len(outbounds) == 0 {
		return nil, nil, errors.New("серверы группы недоступны")
	}
	return outbounds, map[string]any{
		"tag": tag, "selector": []string{prefix}, "fallbackTag": fallback,
		"strategy": map[string]any{"type": "leastPing"},
	}, nil
}

func profileOutbound(p hysteria.Profile, ip netip.Addr, tag string) (map[string]any, error) {
	if p.IsVLESS() {
		port, err := hysteria.VLESSPort(p.Ports)
		if err != nil {
			return nil, err
		}
		return vless.Outbound(p.VLESS, vless.Run{Host: p.Host, Port: port, Dial: ip}, tag)
	}
	ports, err := hysteria.ParsePorts(p.Ports)
	if err != nil {
		return nil, err
	}
	if p.TLS.CA != "" || p.TLS.Insecure && !hy2uri.ValidPin(p.TLS.PinSHA256) {
		return nil, errors.New("неподдерживаемые параметры проверки сертификата")
	}
	name := p.TLS.SNI
	if name == "" {
		name = p.Host
	}
	tls := map[string]any{"serverName": name, "alpn": []string{"h3"}}
	if pin := p.TLS.PinSHA256; pin != "" {
		if !hy2uri.ValidPin(pin) {
			return nil, errors.New("некорректный отпечаток сертификата")
		}
		tls["pinnedPeerCertSha256"] = strings.NewReplacer(":", "", "-", "").Replace(strings.TrimSpace(pin))
	}
	if p.TLS.ECH != "" {
		if !hysteria.ECHInline(p.TLS.ECH) {
			return nil, errors.New("ECH из файла не поддерживается")
		}
		tls["echConfigList"] = p.TLS.ECH
	}
	stream := map[string]any{
		"network": "hysteria", "security": "tls", "tlsSettings": tls,
		"hysteriaSettings": map[string]any{"version": 2, "auth": p.Auth},
	}
	var masks []any
	if len(ports) > 1 || ports[0].From != ports[0].To {
		min, _ := time.ParseDuration(p.Hop.MinInterval)
		max, _ := time.ParseDuration(p.Hop.MaxInterval)
		if min == 0 && max == 0 {
			min, _ = time.ParseDuration(p.Hop.Interval)
			max = min
		}
		settings := map[string]any{"mode": "intervalRemote", "remotePorts": p.Ports}
		if min > 0 && max >= min {
			settings["interval"] = fmt.Sprintf("%d-%d", int(min.Seconds()), int(max.Seconds()))
		}
		masks = append(masks, map[string]any{"type": "udphop", "settings": settings})
	}
	if p.Obfs.Type != "" {
		settings := map[string]any{"password": p.Obfs.Password}
		if strings.EqualFold(p.Obfs.Type, "gecko") {
			settings["minPacketSize"] = p.Obfs.MinPacketSize
			settings["maxPacketSize"] = p.Obfs.MaxPacketSize
		}
		masks = append(masks, map[string]any{"type": strings.ToLower(p.Obfs.Type), "settings": settings})
	}
	if len(masks) > 0 {
		stream["finalmask"] = map[string]any{"udp": masks}
	}
	return map[string]any{
		"tag": tag, "protocol": "hysteria", "streamSettings": stream,
		"settings": map[string]any{"version": 2, "address": ip.String(), "port": ports[0].From},
	}, nil
}

func setDialerProxy(out map[string]any, upstream string) {
	if upstream == "" {
		return
	}
	stream := out["streamSettings"].(map[string]any)
	options, _ := stream["sockopt"].(map[string]any)
	if options == nil {
		options = make(map[string]any)
		stream["sockopt"] = options
	}
	options["dialerProxy"] = upstream
}

func vpnResolve(ctx context.Context, host string) netip.Addr {
	if ip, err := netip.ParseAddr(host); err == nil {
		return ip.Unmap()
	}
	addresses, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(addresses) == 0 {
		return netip.Addr{}
	}
	return addresses[0].Unmap()
}
