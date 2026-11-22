package mobile

import (
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"net/url"
	"slices"
	"strconv"
	"strings"

	"github.com/lardan099/hyroute-mobile/internal/rules"
)

type checkedRoute struct {
	Target string   `json:"target"`
	Action string   `json:"action"`
	Rule   string   `json:"rule"`
	Chain  []string `json:"chain,omitempty"`
	Notes  []string `json:"notes,omitempty"`
}

// CheckClientRoute evaluates saved settings with the tunnel's rule engine
// without resolving the domain, contacting the target, or starting the VPN.
func CheckClientRoute(raw, address, ip, protocol, packageID string, android bool) (string, error) {
	host, port, err := parseRouteTarget(address)
	if err != nil {
		return "", err
	}
	out := checkedRoute{Target: net.JoinHostPort(host, strconv.Itoa(int(port)))}
	var subject rules.Subject
	switch protocol {
	case "tcp":
		subject.Proto = 6
	case "udp":
		subject.Proto = 17
	default:
		return "", errors.New("выберите TCP или UDP")
	}
	domain := host
	destination, addressErr := netip.ParseAddr(host)
	if addressErr == nil {
		domain = ""
	}
	if ip = strings.TrimSpace(ip); ip != "" {
		override, err := netip.ParseAddr(ip)
		if err != nil || override.Zone() != "" {
			return "", errors.New("укажите корректный IP сайта")
		}
		if destination.IsValid() && override.Unmap() != destination.Unmap() {
			return "", errors.New("дополнительный IP должен совпадать с адресом назначения")
		}
		destination = override
	}
	subject.Dst = netip.AddrPortFrom(destination.Unmap(), port)
	plan, err := NewVPNPlan(raw, android)
	if err != nil {
		return "", err
	}
	if android {
		if packageID != "" && !rules.ValidAppPackage(packageID) {
			return "", errors.New("неверный идентификатор приложения")
		}
		if packageID == "" && (len(plan.router.appPackages) > 0 || plan.appScope != "all") {
			return "", errors.New("выберите приложение, чтобы учесть правила Android")
		}
		subject.AppPackage = packageID
		listed := slices.Contains(plan.packages, packageID)
		if plan.appScope == "only" && !listed || plan.appScope == "except" && listed {
			out.Action = "direct"
			out.Rule = "Приложение вне VPN"
			data, err := json.Marshal(out)
			return string(data), err
		}
	}
	if domain != "" && !destination.IsValid() {
		if port == 53 {
			return "", errors.New("для проверки DNS на порту 53 укажите IP")
		}
		out.Notes = append(out.Notes, "IP-правила учтены только при указанном IP.")
	}
	result := plan.evaluateFlow(subject, domain)
	out.Action = result.Action.String()
	out.Rule = result.Rule
	switch {
	case result.NeedsDomain:
		out.Action = "block"
		out.Rule = "Для выбора маршрута нужно имя сайта"
	case result.Action == rules.Tunnel:
		if plan.tags[result.Profile] == "" {
			out.Action = "block"
			out.Notes = append(out.Notes, "VPN-профиль для выбранного маршрута недоступен.")
		} else {
			out.Chain = plan.router.profileChain(result.Profile)
		}
	}
	data, err := json.Marshal(out)
	return string(data), err
}

func parseRouteTarget(raw string) (host string, port uint16, err error) {
	raw = strings.TrimSpace(raw)
	invalid := errors.New("укажите сайт, ссылку HTTP/HTTPS или IP-адрес")
	if raw == "" || len(raw) > 4096 {
		return "", 0, invalid
	}
	if addr, err := netip.ParseAddr(raw); err == nil && addr.Zone() == "" {
		return addr.Unmap().String(), 443, nil
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.User != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return "", 0, invalid
	}
	host = rules.NormalizeDomain(u.Hostname())
	if host == "" || strings.ContainsAny(host, "%*? \\/") || strings.Contains(host, ":") && !validRouteIP(host) {
		return "", 0, invalid
	}
	port = 443
	if u.Scheme == "http" {
		port = 80
	}
	if rawPort := u.Port(); rawPort != "" {
		n, err := strconv.ParseUint(rawPort, 10, 16)
		if err != nil || n == 0 {
			return "", 0, errors.New("укажите порт от 1 до 65535")
		}
		port = uint16(n)
	}
	return host, port, nil
}

func validRouteIP(host string) bool {
	addr, err := netip.ParseAddr(host)
	return err == nil && addr.Zone() == ""
}
