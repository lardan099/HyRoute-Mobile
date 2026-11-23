package mobile

import (
	"bytes"
	"context"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/xtls/xray-core/common/buf"
	xnet "github.com/xtls/xray-core/common/net"
	dnswire "github.com/xtls/xray-core/common/protocol/dns"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/transport"
	"github.com/xtls/xray-core/transport/internet"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/net/idna"
)

const (
	splitDNSTag    = "hyroute-split-dns"
	dnsMessageType = "application/dns-message"
)

type splitDNSSettings struct {
	Tunnel  string   `json:"tunnel"`
	Direct  string   `json:"direct"`
	Domains []string `json:"domains"`
}

func (s *splitDNSSettings) normalize() error {
	if s == nil {
		return nil
	}
	for _, endpoint := range []*string{&s.Tunnel, &s.Direct} {
		*endpoint = strings.TrimSpace(*endpoint)
		u, err := url.Parse(*endpoint)
		if err != nil || u.Scheme != "https" || u.User != nil || u.Fragment != "" || u.Host == "" {
			return errors.New("укажите адрес DNS через HTTPS с IP и путём /dns-query")
		}
		ip, err := netip.ParseAddr(u.Hostname())
		if err != nil || ip.Zone() != "" || ip.IsUnspecified() || ip.IsLoopback() || ip.IsMulticast() || u.Path == "" || u.Path == "/" {
			return errors.New("укажите адрес DNS через HTTPS с IP и путём /dns-query")
		}
	}
	if len(s.Domains) < 1 || len(s.Domains) > 200 {
		return errors.New("укажите от 1 до 200 доменов для DNS напрямую")
	}
	var normalized []string
	for _, domain := range s.Domains {
		domain = strings.TrimSuffix(strings.TrimSpace(domain), ".")
		ascii, err := idna.Lookup.ToASCII(domain)
		if err != nil || ascii == "" || len(ascii) > 253 || strings.ContainsAny(ascii, "/: @*_") {
			return errors.New("укажите домены без схемы, пути и подстановочных знаков")
		}
		if _, err := netip.ParseAddr(ascii); err == nil {
			return errors.New("для раздельного DNS нужны домены")
		}
		for label := range strings.SplitSeq(ascii, ".") {
			if len(label) == 0 || len(label) > 63 {
				return errors.New("некорректный домен для раздельного DNS")
			}
		}
		ascii = strings.ToLower(ascii)
		if !slices.Contains(normalized, ascii) {
			normalized = append(normalized, ascii)
		}
	}
	s.Domains = normalized
	return nil
}

func (s splitDNSSettings) isDirect(domain string) bool {
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	for _, suffix := range s.Domains {
		if domain == suffix || strings.HasSuffix(domain, "."+suffix) {
			return true
		}
	}
	return false
}

// splitDNSProxy forwards complete DNS messages through one of two fixed HTTPS
// resolvers. Its only input is the system DNS flow already captured by the TUN.
type splitDNSProxy struct {
	settings splitDNSSettings
	tunnel   *http.Client
	direct   *http.Client
}

func newSplitDNSProxy(ctx context.Context, plan *VPNPlan) *splitDNSProxy {
	instance := core.MustFromContext(ctx)
	client := func(tag string) *http.Client {
		return &http.Client{
			Timeout:       6 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
			Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
					dest, err := xnet.ParseDestination("tcp:" + address)
					if err != nil {
						return nil, err
					}
					return core.Dial(session.SetForcedOutboundTagToContext(ctx, tag), instance, dest)
				},
				MaxIdleConnsPerHost:    2,
				IdleConnTimeout:        30 * time.Second,
				TLSHandshakeTimeout:    5 * time.Second,
				MaxResponseHeaderBytes: 8192,
				ForceAttemptHTTP2:      true,
			},
		}
	}
	return &splitDNSProxy{settings: *plan.splitDNS, tunnel: client(plan.tags[plan.selected]), direct: client(directTag)}
}

func (p *splitDNSProxy) Close() error {
	p.tunnel.CloseIdleConnections()
	p.direct.CloseIdleConnections()
	return nil
}

func (p *splitDNSProxy) Process(ctx context.Context, link *transport.Link, _ internet.Dialer) error {
	outbounds := session.OutboundsFromContext(ctx)
	tcp := outbounds[len(outbounds)-1].Target.Network == xnet.Network_TCP
	var reader dnswire.MessageReader = &dnswire.UDPReader{Reader: link.Reader}
	var writer dnswire.MessageWriter = &dnswire.UDPWriter{Writer: link.Writer}
	if tcp {
		reader = dnswire.NewTCPReader(link.Reader)
		writer = &dnswire.TCPWriter{Writer: link.Writer}
	}
	for {
		packet, err := reader.ReadMessage()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		response := p.answer(ctx, packet.Bytes(), tcp)
		packet.Release()
		if len(response) != 0 {
			if err := writer.WriteMessage(buf.FromBytes(response)); err != nil {
				return err
			}
		}
	}
}

func (p *splitDNSProxy) answer(ctx context.Context, raw []byte, tcp bool) []byte {
	var query dnsmessage.Message
	if err := query.Unpack(raw); err != nil || query.Response || query.OpCode != 0 || len(query.Questions) != 1 {
		return nil
	}
	endpoint, client := p.settings.Tunnel, p.tunnel
	if p.settings.isDirect(query.Questions[0].Name.String()) {
		endpoint, client = p.settings.Direct, p.direct
	}
	response := exchangeDNS(ctx, client, endpoint, raw, query)
	if response != nil && (tcp || len(response) <= udpDNSLimit(query)) {
		return response
	}
	reply := dnsmessage.Message{Header: dnsmessage.Header{
		ID: query.ID, Response: true, RecursionDesired: query.RecursionDesired, Truncated: response != nil,
	}, Questions: query.Questions}
	if response == nil {
		reply.RCode = dnsmessage.RCodeServerFailure
	}
	wire, _ := reply.Pack()
	return wire
}

func udpDNSLimit(query dnsmessage.Message) int {
	for _, option := range query.Additionals {
		if option.Header.Type == dnsmessage.TypeOPT {
			return min(max(int(option.Header.Class), 512), 1232)
		}
	}
	return 512
}

func exchangeDNS(ctx context.Context, client *http.Client, endpoint string, raw []byte, query dnsmessage.Message) []byte {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(raw))
	if err != nil {
		return nil
	}
	request.Header.Set("Content-Type", dnsMessageType)
	request.Header.Set("Accept", dnsMessageType)
	response, err := client.Do(request)
	if err != nil {
		return nil
	}
	defer response.Body.Close()
	mediaType, _, _ := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if response.StatusCode != http.StatusOK || mediaType != dnsMessageType {
		return nil
	}
	wire, err := io.ReadAll(io.LimitReader(response.Body, 65536))
	var reply dnsmessage.Message
	if err != nil || len(wire) > 65535 || reply.Unpack(wire) != nil || !reply.Response || reply.ID != query.ID || len(reply.Questions) != 1 {
		return nil
	}
	want, got := query.Questions[0], reply.Questions[0]
	if !strings.EqualFold(want.Name.String(), got.Name.String()) || want.Type != got.Type || want.Class != got.Class {
		return nil
	}
	return wire
}
