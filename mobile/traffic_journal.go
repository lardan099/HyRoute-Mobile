package mobile

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"

	"github.com/lardan099/hyroute-mobile/internal/hysteria"
	"github.com/xtls/xray-core/common"
	xctx "github.com/xtls/xray-core/common/ctx"
	xerrors "github.com/xtls/xray-core/common/errors"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	routingsession "github.com/xtls/xray-core/features/routing/session"
	"github.com/xtls/xray-core/proxy"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"github.com/xtls/xray-core/transport/internet/stat"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

const trafficJournalCapacity = 120

type trafficEvent struct {
	ID          uint64 `json:"id"`
	Flow        uint32 `json:"flow"`
	Time        int64  `json:"time"`
	Stage       string `json:"stage"`
	Destination string `json:"destination"`
	Profile     string `json:"profile"`
	Rule        string `json:"rule,omitempty"`
	Error       string `json:"error,omitempty"`
}

type trafficJournal struct {
	enabled atomic.Bool
	mu      sync.Mutex
	events  [trafficJournalCapacity]trafficEvent
	total   uint64
	size    int
}

func (j *trafficJournal) append(event trafficEvent) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !j.enabled.Load() {
		return
	}
	j.total++
	event.ID = j.total
	event.Time = time.Now().UnixMilli()
	event.Destination = trafficText(event.Destination)
	event.Profile = trafficText(event.Profile)
	event.Rule = trafficText(event.Rule)
	j.events[(j.total-1)%trafficJournalCapacity] = event
	if j.size < trafficJournalCapacity {
		j.size++
	}
}

func (j *trafficJournal) snapshot() string {
	j.mu.Lock()
	events := make([]trafficEvent, 0, j.size)
	for i := 0; i < j.size; i++ {
		events = append(events, j.events[(j.total-1-uint64(i))%trafficJournalCapacity])
	}
	j.mu.Unlock()
	// Keep the provider message small even with long Unicode profile names.
	for {
		encoded, _ := json.Marshal(events)
		if len(encoded) <= 48*1024 {
			return string(encoded)
		}
		events = events[:len(events)/2]
	}
}

func (s *VPNSession) SetTrafficLogging(enabled bool) {
	if s.traffic != nil {
		s.traffic.enabled.Store(enabled)
	}
}

func (s *VPNSession) TrafficEvents() string {
	if s.traffic == nil {
		return "[]"
	}
	return s.traffic.snapshot()
}

func (s *VPNSession) ClearTrafficEvents() {
	if s.traffic != nil {
		s.traffic.mu.Lock()
		clear(s.traffic.events[:])
		s.traffic.size = 0
		s.traffic.mu.Unlock()
	}
}

func trafficText(s string) string {
	var text strings.Builder
	for _, r := range s {
		if text.Len() >= 160 {
			break
		}
		if !unicode.IsControl(r) && !unicode.Is(unicode.Cf, r) {
			text.WriteRune(r)
		}
	}
	return text.String()
}

func journalProfileName(p hysteria.Profile) string {
	if p.Name != "" {
		return p.Name
	}
	return p.Host
}

type trafficContextKey struct{}
type trafficFlowKey struct{}

type trafficConfiguration struct {
	network *vpnConfiguration
	proxies []trafficProxy
}

type trafficProxy struct {
	tag    string
	config *serial.TypedMessage
}

func init() {
	common.Must(common.RegisterConfig((*wrapperspb.UInt32Value)(nil), func(ctx context.Context, raw any) (any, error) {
		state, ok := ctx.Value(trafficContextKey{}).(trafficConfiguration)
		index := raw.(*wrapperspb.UInt32Value).Value
		if !ok || int(index) >= len(state.proxies) {
			return nil, errors.New("missing HyRoute outbound for traffic journal")
		}
		target := state.proxies[index]
		configuration, err := target.config.GetInstance()
		if err != nil {
			return nil, err
		}
		outbound, err := common.CreateObject(ctx, configuration)
		if err != nil {
			return nil, err
		}
		return &trafficOutbound{Outbound: outbound.(proxy.Outbound), network: state.network, tag: target.tag}, nil
	}))
}

func (p *vpnConfiguration) instrumentTraffic(ctx context.Context, config *core.Config) context.Context {
	if p.traffic == nil {
		return ctx
	}
	state := trafficConfiguration{network: p, proxies: make([]trafficProxy, len(config.Outbound))}
	for i, outbound := range config.Outbound {
		if outbound.Tag == probeTag {
			continue
		}
		state.proxies[i] = trafficProxy{tag: outbound.Tag, config: outbound.ProxySettings}
		outbound.ProxySettings = serial.ToTypedMessage(wrapperspb.UInt32(uint32(i)))
	}
	return context.WithValue(ctx, trafficContextKey{}, state)
}

type trafficOutbound struct {
	proxy.Outbound
	network *vpnConfiguration
	tag     string
}

func (p *trafficOutbound) Close() error { return common.Close(p.Outbound) }

func (p *trafficOutbound) Process(ctx context.Context, link *transport.Link, dialer internet.Dialer) error {
	journal := p.network.traffic
	inbound := session.InboundFromContext(ctx)
	flow := uint32(xctx.IDFromContext(ctx))
	if !journal.enabled.Load() || inbound == nil || flow == 0 {
		return p.Outbound.Process(ctx, link, dialer)
	}
	outbounds := session.OutboundsFromContext(ctx)
	target := outbounds[len(outbounds)-1].Target
	event := trafficEvent{Flow: flow, Stage: "hop", Destination: target.String(), Profile: p.network.labels[p.tag]}
	if ctx.Value(trafficFlowKey{}) == nil && inbound.Tag == "hyroute-tun" {
		ctx = context.WithValue(ctx, trafficFlowKey{}, true)
		event.Stage = "route"
		route := routingsession.AsRoutingContext(ctx)
		if domain := route.GetTargetDomain(); domain != "" {
			event.Destination = strings.ToLower(target.Network.String()) + ":" + net.JoinHostPort(domain, route.GetTargetPort().String())
		}
		event.Rule = p.network.plan.evaluateFlow(vpnSubject(route), route.GetTargetDomain()).Rule
		if event.Rule == "" || event.Rule == "default" {
			event.Rule = "Остальной трафик"
		}
	}
	if ctx.Value(trafficFlowKey{}) == nil {
		return p.Outbound.Process(ctx, link, dialer)
	}
	if p.tag == blockTag {
		event.Stage = "blocked"
	}
	journal.append(event)
	err := p.Outbound.Process(ctx, link, trafficDialer{Dialer: dialer, journal: journal, event: event})
	if reason := trafficError(err); reason != "" {
		event.Stage, event.Error = "error", reason
		journal.append(event)
	}
	return err
}

type trafficDialer struct {
	internet.Dialer
	journal *trafficJournal
	event   trafficEvent
}

func (d trafficDialer) Dial(ctx context.Context, destination xnet.Destination) (stat.Connection, error) {
	conn, err := d.Dialer.Dial(ctx, destination)
	if reason := trafficError(err); reason != "" {
		event := d.event
		event.Stage, event.Destination, event.Error = "dialError", destination.String(), reason
		d.journal.append(event)
	}
	return conn, err
}

func trafficError(err error) string {
	if err == nil {
		return ""
	}
	err = xerrors.Cause(err)
	var dns *net.DNSError
	var certificate *tls.CertificateVerificationError
	var authority x509.UnknownAuthorityError
	var network net.Error
	switch {
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrClosedPipe), errors.Is(err, net.ErrClosed), errors.Is(err, context.Canceled):
		return ""
	case errors.As(err, &dns):
		return "Ошибка DNS"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "В соединении отказано"
	case errors.Is(err, syscall.ECONNRESET):
		return "Соединение сброшено"
	case errors.Is(err, syscall.ENETUNREACH), errors.Is(err, syscall.EHOSTUNREACH):
		return "Адрес недоступен"
	case errors.As(err, &certificate), errors.As(err, &authority):
		return "Не удалось проверить сертификат"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &network) && network.Timeout():
		return "Истекло время ожидания"
	default:
		return "Ошибка передачи"
	}
}
