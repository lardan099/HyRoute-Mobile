package mobile

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/lardan099/hyroute-mobile/internal/vless"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/outbound"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
)

const probeTag = "hyroute-probe"

type probeHandlerKey struct{}

// probeOutbound dispatches a test through its private handler without changing
// the active VPN's outbound manager or exposing the test port.
type probeOutbound struct{}

func (probeOutbound) Process(ctx context.Context, link *transport.Link, _ internet.Dialer) error {
	handler, ok := ctx.Value(probeHandlerKey{}).(outbound.Handler)
	if !ok {
		return errors.New("missing probe handler")
	}
	handler.Dispatch(ctx, link)
	return nil
}

type probeTarget struct {
	profile hysteria.Profile
	node    *vless.Node
}

type probeResult struct {
	ProfileID string `json:"profileId"`
	Name      string `json:"name"`
	Host      string `json:"host,omitempty"`
	Status    string `json:"status"`
	Millis    int64  `json:"ms,omitempty"`
}

// ProbeBatch runs a bounded number of independent HTTPS checks and publishes
// partial results without exposing the underlying connection configurations.
type ProbeBatch struct {
	mu      sync.Mutex
	results []probeResult
	done    bool
	cancel  context.CancelFunc
}

// StartProbe checks a subscription or a selected profile (including all its nodes).
func StartProbe(raw, scope, id, journal string) (*ProbeBatch, error) {
	return startProbe(raw, scope, id, journal, vless.ProbeURL)
}

func startProbe(raw, scope, id, journal, targetURL string) (*ProbeBatch, error) {
	state, err := decodeClientState(raw)
	if err != nil {
		return nil, err
	}
	if (scope != "subscription" && scope != "profile") || id == "" {
		return nil, errors.New("выберите сервер или подписку")
	}
	var targets []probeTarget
	var results []probeResult
	if len(state.ServerGroups) > 0 {
		servers, _ := state.groupCandidates()
		for _, group := range state.ServerGroups {
			if !(scope == "profile" && id == group.ID || scope == "subscription" && id == groupSubscriptionID) {
				continue
			}
			for _, member := range group.memberIDs() {
				candidate, ok := servers[member]
				if !ok {
					continue
				}
				targets = append(targets, probeTarget{profile: candidate.profile, node: candidate.node})
				results = append(results, probeResult{ProfileID: group.ID, Name: candidate.profile.Name, Host: candidate.profile.Host, Status: "pending"})
			}
		}
	}
	for _, item := range state.Subscriptions {
		if scope == "subscription" && item.ID != id {
			continue
		}
		for _, profile := range item.Snapshot.Servers {
			if profile.Missing || (scope == "profile" && profile.ID != id) {
				continue
			}
			if profile.Balance == nil {
				targets = append(targets, probeTarget{profile: profile})
				results = append(results, probeResult{ProfileID: profile.ID, Name: profile.Name, Host: profile.Host, Status: "pending"})
				continue
			}
			for i := range profile.Balance.Nodes {
				node := &profile.Balance.Nodes[i]
				targets = append(targets, probeTarget{node: node})
				results = append(results, probeResult{ProfileID: profile.ID, Name: fmt.Sprintf("%s · узел %d", profile.Name, i+1), Host: node.Host, Status: "pending"})
			}
		}
	}
	if len(targets) == 0 {
		return nil, errors.New("нет доступных серверов для проверки")
	}
	ctx, cancel := context.WithCancel(context.Background())
	batch := &ProbeBatch{results: results, cancel: cancel}
	RecordVPNEvent(journal, "probe_start")
	go batch.run(ctx, targets, targetURL, journal)
	return batch, nil
}

func (b *ProbeBatch) run(ctx context.Context, targets []probeTarget, url, journal string) {
	jobs := make(chan int)
	var workers sync.WaitGroup
	for range min(len(targets), 4) {
		workers.Go(func() {
			for index := range jobs {
				b.mu.Lock()
				b.results[index].Status = "running"
				b.mu.Unlock()
				check, cancel := context.WithTimeout(ctx, 7*time.Second)
				status, ms := targets[index].measure(check, url, nil)
				if ctx.Err() != nil {
					status = "cancelled"
				} else if check.Err() == context.DeadlineExceeded {
					status = "timeout"
				}
				cancel()
				b.mu.Lock()
				b.results[index].Status, b.results[index].Millis = status, ms
				b.mu.Unlock()
			}
		})
	}
schedule:
	for index := range targets {
		select {
		case jobs <- index:
		case <-ctx.Done():
			break schedule
		}
	}
	close(jobs)
	workers.Wait()
	if ctx.Err() != nil {
		RecordVPNEvent(journal, "probe_cancel")
	} else {
		RecordVPNEvent(journal, "probe_done")
	}
	b.mu.Lock()
	for i := range b.results {
		if b.results[i].Status == "pending" {
			b.results[i].Status = "cancelled"
		}
	}
	b.done = true
	b.mu.Unlock()
	b.cancel()
}

func (b *ProbeBatch) Snapshot() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	data, _ := json.Marshal(struct {
		Done    bool          `json:"done"`
		Results []probeResult `json:"results"`
	}{b.done, b.results})
	return string(data)
}

func (b *ProbeBatch) Cancel() { b.cancel() }

func (p probeTarget) measure(ctx context.Context, url string, active *core.Instance) (string, int64) {
	host := p.profile.Host
	if p.node != nil {
		host = p.node.Host
	}
	ip := vpnResolve(ctx, host)
	if !ip.IsValid() {
		return "dns", 0
	}
	tag := probeTag + "-" + rand.Text()
	var proxySettings map[string]any
	var err error
	if p.node != nil {
		proxySettings, err = p.node.Outbound(ip, tag)
	} else {
		proxySettings, err = profileOutbound(p.profile, ip, tag)
	}
	if err != nil {
		return "configuration", 0
	}
	config, err := json.Marshal(map[string]any{
		"log": map[string]any{"loglevel": "none", "access": "none"}, "outbounds": []any{proxySettings},
	})
	if err != nil {
		return "configuration", 0
	}
	dial, closeProbe, err := startProbeOutbound(active, config, tag)
	if err != nil {
		return "configuration", 0
	}
	defer closeProbe()
	transport := &http.Transport{
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + addr)
			if err != nil {
				return nil, err
			}
			return dial(ctx, dest)
		},
	}
	defer transport.CloseIdleConnections()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "configuration", 0
	}
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	started := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return "connection", 0
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return "response", 0
	}
	return "ok", max(1, time.Since(started).Milliseconds())
}

func startProbeOutbound(active *core.Instance, config []byte, tag string) (func(context.Context, xnet.Destination) (net.Conn, error), func(), error) {
	if active == nil {
		vpnRuntime.Lock()
		if vpnRuntime.session == nil {
			instance, err := core.StartInstance("json", config)
			vpnRuntime.Unlock()
			if err != nil {
				return nil, nil, err
			}
			return func(ctx context.Context, dest xnet.Destination) (net.Conn, error) {
				return core.Dial(session.SetForcedOutboundTagToContext(ctx, tag), instance, dest)
			}, func() { _ = instance.Close() }, nil
		}
		active = vpnRuntime.session.instance
		vpnRuntime.Unlock()
	}
	// Creating a second Xray instance would replace the process-wide outbound
	// manager used for chain dials. Give each test an isolated outbound instead.
	parsed, err := core.LoadConfig("json", bytes.NewReader(config))
	if err != nil {
		return nil, nil, err
	}
	created, err := core.CreateObject(active, parsed.Outbound[0])
	if err != nil {
		return nil, nil, err
	}
	handler := created.(outbound.Handler)
	if err := handler.Start(); err != nil {
		_ = handler.Close()
		return nil, nil, err
	}
	return func(ctx context.Context, dest xnet.Destination) (net.Conn, error) {
		ctx = context.WithValue(ctx, probeHandlerKey{}, handler)
		return core.Dial(session.SetForcedOutboundTagToContext(ctx, probeTag), active, dest)
	}, func() { _ = handler.Close() }, nil
}
