package subscription

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/subfmt"
)

// MaxBodySize is the maximum size of a downloaded subscription body.
const MaxBodySize = 5 << 20

// HasVLESSLinks reports whether a plain or base64 response contains VLESS
// links. Some providers can return an Xray config for the same response.
func HasVLESSLinks(body []byte) bool {
	return slices.ContainsFunc(ParseLinks(string(body)).Profiles, func(p hysteria.Profile) bool {
		return p.IsVLESS()
	})
}

// HasXrayBalancer reports whether body contains a supported Xray balancer.
func HasXrayBalancer(body []byte) bool {
	parsed, err := Parse(body)
	return err == nil && slices.ContainsFunc(parsed.Profiles, func(p hysteria.Profile) bool {
		return p.Balance != nil
	})
}

// maxSubServers bounds the servers taken from one subscription: each is a
// profile kept, sealed and merged on every update while the controller
// waits, and public aggregators list thousands.
const maxSubServers = 3000

// capServers keeps the first maxSubServers servers of l, with a warning.
func capServers(l Links) Links {
	if n := len(l.Profiles); n > maxSubServers {
		l.Profiles = l.Profiles[:maxSubServers]
		l.Warnings = append(l.Warnings, fmt.Sprintf("в подписке %d серверов: взяты первые %d", n, maxSubServers))
	}
	return l
}

// Parse turns a body into profiles or an error that explains
// what came instead. A list of share links (plain or base64) is the usual
// body; Clash, sing-box and Xray configs are read too (subfmt).
func Parse(body []byte) (Links, error) {
	t := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(body)), "\ufeff"))
	prefix := strings.ToLower(t[:min(len(t), len("<!doctype"))])
	html := strings.HasPrefix(prefix, "<!doctype") || strings.HasPrefix(prefix, "<html")
	json := strings.HasPrefix(t, "{") || strings.HasPrefix(t, "[")
	var l Links
	if r, ok := subfmt.Convert(body); ok {
		// The document's routes and inbounds are not links to import.
		l = ParseLinks(strings.Join(r.Links, "\n"))
		profiles := make([]hysteria.Profile, 0, len(r.Balancers)+len(l.Profiles))
		for _, b := range r.Balancers {
			profiles = append(profiles, hysteria.Profile{Name: b.Name, Protocol: hysteria.ProtoVLESS, Balance: &b.Balance})
		}
		l.Profiles = append(profiles, l.Profiles...)
		l.Format = r.Format
		l.Warnings = append(r.Warnings, l.Warnings...)
		l.Errors = append(r.Errors, l.Errors...)
		for k, v := range r.Other {
			l.Ignored[k] += v
		}
	} else if !json && !html {
		l = ParseLinks(t)
	}
	if len(l.Profiles) > 0 {
		return capServers(l), nil
	}
	switch {
	case len(l.Notices) > 0:
		// The panel says why it sent no servers: device limit, an
		// expired account, an app it does not serve.
		return l, fmt.Errorf("панель прислала вместо серверов сообщение: «%s»", strings.Join(l.Notices, "», «"))
	case t == "":
		return l, errors.New("подписка пустая")
	case html:
		return l, errors.New("сервер вернул веб-страницу, а не подписку: проверьте ссылку")
	case len(l.Errors) > 0:
		// Its own links come first: the other protocols are not the issue.
		msg := fmt.Sprintf("ни один сервер Hysteria 2 или VLESS не разобран (%d): %s", len(l.Errors), l.Errors[0])
		if l.IgnoredTotal() > 0 {
			msg += "; других протоколов: " + ignoredText(l.Ignored)
		}
		return l, errors.New(msg)
	case l.IgnoredTotal() > 0:
		return l, fmt.Errorf("в подписке нет серверов Hysteria 2 и VLESS, только другие протоколы (%s)", ignoredText(l.Ignored))
	case l.Format != "":
		return l, fmt.Errorf("в конфиге %s нет серверов", l.Format)
	case json:
		return l, errors.New("JSON без серверов: HyRoute читает конфиги sing-box и Xray и списки ссылок")
	case !strings.ContainsAny(t, "\r\n") && utf8.RuneCountInString(t) <= 200:
		// A panel's short answer in words ("подписка истекла…") says more
		// than any guess.
		return l, fmt.Errorf("сервер подписки ответил текстом, а не ссылками: «%s»", t)
	}
	return l, errors.New("в ответе нет ссылок hysteria2://, hy2:// или vless://")
}

func ignoredText(m map[string]int) string {
	var parts []string
	for k, v := range m {
		parts = append(parts, fmt.Sprintf("%s: %d", k, v))
	}
	slices.Sort(parts)
	return strings.Join(parts, ", ")
}
