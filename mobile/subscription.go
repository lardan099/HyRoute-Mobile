// Package mobile provides the shared subscription and routing logic for mobile
// clients. Its public API uses types supported by Go mobile bindings.
package mobile

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hy2uri"
	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/subscription"
)

var subscriptionClient = &http.Client{
	Timeout:       30 * time.Second,
	CheckRedirect: subscriptionRedirect,
	Transport: &http.Transport{
		ForceAttemptHTTP2:      true,
		IdleConnTimeout:        90 * time.Second,
		MaxResponseHeaderBytes: 64 << 10,
	},
}

type importedSubscription struct {
	subscription.PanelInfo
	Format   string             `json:"format"`
	Servers  []hysteria.Profile `json:"servers"`
	Ignored  map[string]int     `json:"ignored,omitempty"`
	Rejected int                `json:"rejected,omitempty"`
	Warnings []string           `json:"warnings,omitempty"`
}

// FetchSubscription downloads and imports servers from an HTTPS subscription URL.
// Call it off the UI thread. The returned JSON contains connection credentials.
func FetchSubscription(rawURL string) (string, error) {
	return fetchSubscription(subscriptionClient, rawURL)
}

func fetchSubscription(client *http.Client, rawURL string) (string, error) {
	request, err := http.NewRequest(http.MethodGet, strings.TrimSpace(rawURL), nil)
	if err != nil || request.URL.Hostname() == "" || request.URL.Scheme != "https" {
		return "", errors.New("нужна ссылка подписки https://")
	}
	request.Header.Set("Accept", "text/plain, application/json, */*")
	body, headers, err := requestSubscription(client, request)
	if err != nil {
		return "", err
	}
	if headers.Get("Profile-Web-Page-Url") != "" && subscription.HasVLESSLinks(body) {
		ctx, cancel := context.WithTimeout(request.Context(), 10*time.Second)
		defer cancel()
		alternate := request.Clone(ctx)
		alternate.Header.Set("User-Agent", "Happ/HyRoute")
		alternate.Header.Set("Accept", "application/json, */*")
		if altBody, altHeaders, err := requestSubscription(client, alternate); err == nil && subscription.HasXrayBalancer(altBody) {
			body, headers = altBody, altHeaders
		}
	}
	return importSubscription(body, subscription.ReadPanelHeaders(headers).Clean())
}

func requestSubscription(client *http.Client, request *http.Request) ([]byte, http.Header, error) {
	response, err := client.Do(request)
	if err != nil {
		// Request errors can contain the entire URL, including its token.
		return nil, nil, errors.New("сервер подписки недоступен")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("сервер подписки ответил HTTP %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, subscription.MaxBodySize+1))
	if err != nil {
		return nil, nil, errors.New("ответ подписки оборван")
	}
	if len(body) > subscription.MaxBodySize {
		return nil, nil, errors.New("ответ подписки больше 5 МБ")
	}
	return body, response.Header, nil
}

func subscriptionRedirect(request *http.Request, via []*http.Request) error {
	if request.URL.Scheme != "https" {
		return errors.New("перенаправление подписки требует HTTPS")
	}
	if len(via) >= 10 {
		return errors.New("слишком много перенаправлений")
	}
	// Subscription URLs often carry an access token in the path or query.
	request.Header.Del("Referer")
	if !strings.EqualFold(request.URL.Host, via[0].URL.Host) {
		request.Header.Del("Authorization")
		request.Header.Del("User-Agent")
	}
	return nil
}

// ImportSubscription reads a downloaded subscription or pasted share links.
// The returned JSON contains connection credentials. Keep it in private storage.
func ImportSubscription(body []byte) (string, error) {
	return importSubscription(body, subscription.PanelInfo{})
}

func importSubscription(body []byte, info subscription.PanelInfo) (string, error) {
	if len(body) > subscription.MaxBodySize {
		return "", errors.New("ответ подписки больше 5 МБ")
	}
	parsed, err := subscription.Parse(body)
	if err != nil {
		return "", err
	}
	format := parsed.Format
	if format == "" {
		format = "links"
		if parsed.Base64 {
			format = "base64"
		}
	}
	return marshalSubscription(importedSubscription{
		PanelInfo: info,
		Format:    format,
		Servers:   parsed.Profiles,
		Ignored:   parsed.Ignored,
		Rejected:  len(parsed.Errors),
		Warnings:  parsed.Warnings,
	})
}

// MergeSubscription applies one freshly imported subscription to its saved JSON
// snapshot. referencedIDsJSON is the JSON array of server IDs used by local
// rules, groups and the currently selected server.
func MergeSubscription(previousJSON, importedJSON, referencedIDsJSON string) (string, error) {
	var previous, fresh importedSubscription
	if previousJSON != "" {
		if err := json.Unmarshal([]byte(previousJSON), &previous); err != nil {
			return "", errors.New("сохранённая подписка повреждена")
		}
	}
	if err := json.Unmarshal([]byte(importedJSON), &fresh); err != nil || len(fresh.Servers) == 0 {
		return "", errors.New("в новой подписке нет серверов")
	}
	if replacesXrayBalancer(previous.Servers, fresh.Servers) {
		return "", errors.New("панель не вернула конфигурацию балансировщика Xray. Сохранён предыдущий профиль")
	}
	var referenced []string
	if referencedIDsJSON != "" {
		if err := json.Unmarshal([]byte(referencedIDsJSON), &referenced); err != nil {
			return "", errors.New("список используемых серверов повреждён")
		}
	}
	keep := make(map[string]bool, len(referenced))
	for _, id := range referenced {
		keep[id] = true
	}
	fresh.Servers, _ = subscription.Merge(previous.Servers, "", fresh.Servers, func(id string) bool {
		return keep[id]
	}, rand.Text)
	raw, err := json.Marshal(fresh)
	return string(raw), err
}

func replacesXrayBalancer(previous, fresh []hysteria.Profile) bool {
	balancers := make(map[string]bool, len(fresh))
	for _, server := range fresh {
		balancers[server.Name] = balancers[server.Name] || server.Balance != nil
	}
	for _, server := range previous {
		if balanced, found := balancers[server.Name]; server.Balance != nil && found && !balanced {
			return true
		}
	}
	return false
}

func marshalSubscription(result importedSubscription) (string, error) {
	count := len(result.Servers)
	result.Servers = slices.DeleteFunc(result.Servers, func(server hysteria.Profile) bool {
		return server.TLS.Insecure && !hy2uri.ValidPin(server.TLS.PinSHA256)
	})
	if skipped := count - len(result.Servers); skipped > 0 {
		const reason = "отключена проверка сертификата и нет действительного отпечатка SHA-256"
		if len(result.Servers) == 0 {
			return "", fmt.Errorf("нет серверов с проверкой подлинности: %s", reason)
		}
		result.Rejected += skipped
		result.Warnings = append(result.Warnings, fmt.Sprintf("пропущено серверов (%d): %s", skipped, reason))
	}
	result.Servers, _ = subscription.Merge(nil, "", result.Servers, nil, rand.Text)
	raw, err := json.Marshal(result)
	return string(raw), err
}
