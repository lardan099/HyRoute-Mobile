package mobile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/lardan099/hyroute-mobile/internal/rules"

	_ "github.com/xtls/xray-core/app/dispatcher"
	_ "github.com/xtls/xray-core/app/log"
	_ "github.com/xtls/xray-core/app/observatory"
	_ "github.com/xtls/xray-core/app/observatory/burst"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	xrouter "github.com/xtls/xray-core/app/router"
	"github.com/xtls/xray-core/common"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/routing"
	_ "github.com/xtls/xray-core/main/json"
	_ "github.com/xtls/xray-core/proxy/blackhole"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/hysteria"
	_ "github.com/xtls/xray-core/proxy/loopback"
	_ "github.com/xtls/xray-core/proxy/vless/outbound"
	"github.com/xtls/xray-core/transport/internet"
	_ "github.com/xtls/xray-core/transport/internet/grpc"
	_ "github.com/xtls/xray-core/transport/internet/httpupgrade"
	_ "github.com/xtls/xray-core/transport/internet/kcp"
	_ "github.com/xtls/xray-core/transport/internet/reality"
	_ "github.com/xtls/xray-core/transport/internet/splithttp"
	_ "github.com/xtls/xray-core/transport/internet/tagged/taggedimpl"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
	_ "github.com/xtls/xray-core/transport/internet/websocket"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// VPNPlatform protects Android sockets and identifies the owner of a flow.
// PackageForFlow returns an empty string for an identified, unrouted app and
// "?" if ownership cannot be established safely.
type VPNPlatform interface {
	Protect(fd int32) bool
	PackageForFlow(protocol, source string, sourcePort int32, target string, targetPort int32) string
}

// VPNPrepared is a validated, resolved network plan. Prepare it before
// installing the OS VPN so bootstrap DNS cannot recurse through the tunnel.
type VPNPrepared struct{ config *vpnConfiguration }

func (p *VPNPlan) Prepare() (*VPNPrepared, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	config, err := p.configuration(ctx, true, vpnResolve)
	if err != nil {
		return nil, err
	}
	return &VPNPrepared{config: config}, nil
}

type activePlatform struct{ platform VPNPlatform }

var vpnRuntime struct {
	sync.Mutex
	session *VPNSession
	sockets atomic.Pointer[activePlatform]
}

type vpnContextKey struct{}

type vpnContextValue struct {
	configuration *vpnConfiguration
	platform      VPNPlatform
}

func init() {
	common.Must(common.RegisterConfig((*wrapperspb.BytesValue)(nil), func(ctx context.Context, raw any) (any, error) {
		state, ok := ctx.Value(vpnContextKey{}).(vpnContextValue)
		if !ok {
			return nil, errors.New("missing HyRoute VPN configuration")
		}
		var config xrouter.Config
		if err := proto.Unmarshal(raw.(*wrapperspb.BytesValue).Value, &config); err != nil {
			return nil, err
		}
		delegate, err := common.CreateObject(ctx, &config)
		if err != nil {
			return nil, err
		}
		return &vpnFlowRouter{Router: delegate.(routing.Router), vpnContextValue: state}, nil
	}))
	common.Must(common.RegisterConfig((*wrapperspb.StringValue)(nil), func(ctx context.Context, raw any) (any, error) {
		if raw.(*wrapperspb.StringValue).Value == probeTag {
			return probeOutbound{}, nil
		}
		state, ok := ctx.Value(vpnContextKey{}).(vpnContextValue)
		if !ok || state.configuration.plan.splitDNS == nil || raw.(*wrapperspb.StringValue).Value != splitDNSTag {
			return nil, errors.New("missing HyRoute DNS configuration")
		}
		return newSplitDNSProxy(ctx, state.configuration.plan), nil
	}))
	common.Must(internet.RegisterDialerController(func(_, _ string, conn syscall.RawConn) error {
		platform := vpnRuntime.sockets.Load()
		if platform == nil {
			return nil
		}
		var protected bool
		if err := conn.Control(func(fd uintptr) { protected = platform.platform.Protect(int32(fd)) }); err != nil {
			return err
		}
		if !protected {
			return errors.New("failed to protect VPN socket")
		}
		return nil
	}))
}

// VPNSession owns the embedded engine and its duplicate of the supplied TUN
// descriptor. The caller remains responsible for the original descriptor.
type VPNSession struct {
	instance *core.Instance
	cancel   context.CancelFunc
	traffic  *trafficJournal
}

func (p *VPNPrepared) Start(fd int32, platformImpl VPNPlatform) (*VPNSession, error) {
	if fd < 3 || (p.config.plan.android && platformImpl == nil) {
		return nil, errors.New("нет системного интерфейса VPN")
	}
	vpnRuntime.Lock()
	defer vpnRuntime.Unlock()
	if vpnRuntime.session != nil {
		return nil, errors.New("VPN уже запущен")
	}
	if platformImpl != nil {
		vpnRuntime.sockets.Store(&activePlatform{platformImpl})
	}
	if err := os.Setenv(platform.TunFdKey, strconv.Itoa(int(fd))); err != nil {
		vpnRuntime.sockets.Store(nil)
		return nil, err
	}
	defer os.Unsetenv(platform.TunFdKey)
	ctx, cancel := context.WithCancel(context.Background())
	instance, err := p.config.start(ctx, platformImpl)
	if err != nil {
		cancel()
		vpnRuntime.sockets.Store(nil)
		return nil, errors.New("не удалось запустить сетевое ядро")
	}
	session := &VPNSession{instance: instance, cancel: cancel, traffic: p.config.traffic}
	vpnRuntime.session = session
	return session, nil
}

func (s *VPNSession) Stop() {
	vpnRuntime.Lock()
	defer vpnRuntime.Unlock()
	if vpnRuntime.session != s {
		return
	}
	s.cancel()
	_ = s.instance.Close()
	vpnRuntime.session = nil
	// Retain the last controller until the next start. A socket from a
	// closing flow must still pass protection rather than escape unprotected.
}

// ReleaseVPNProtection is called only after Android closes its TUN descriptor.
func ReleaseVPNProtection() {
	vpnRuntime.Lock()
	defer vpnRuntime.Unlock()
	if vpnRuntime.session == nil {
		vpnRuntime.sockets.Store(nil)
	}
}

func (p *vpnConfiguration) start(ctx context.Context, hooks VPNPlatform) (*core.Instance, error) {
	raw, err := json.Marshal(p.xray)
	if err != nil {
		return nil, err
	}
	config, err := core.LoadConfig("json", bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	routingType := string((&xrouter.Config{}).ProtoReflect().Descriptor().FullName())
	for i, feature := range config.App {
		if feature.Type == routingType {
			config.App[i] = serial.ToTypedMessage(wrapperspb.Bytes(feature.Value))
		}
	}
	for _, outbound := range config.Outbound {
		if outbound.Tag == splitDNSTag || outbound.Tag == probeTag {
			outbound.ProxySettings = serial.ToTypedMessage(wrapperspb.String(outbound.Tag))
		}
	}
	ctx = p.instrumentTraffic(ctx, config)
	ctx = context.WithValue(ctx, vpnContextKey{}, vpnContextValue{p, hooks})
	instance, err := core.NewWithContext(ctx, config)
	if err != nil {
		return nil, err
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return nil, err
	}
	return instance, nil
}

type vpnFlowRouter struct {
	routing.Router
	vpnContextValue
}

type vpnFlowRoute struct {
	routing.Context
	tag string
}

func (r vpnFlowRoute) GetOutboundGroupTags() []string { return nil }
func (r vpnFlowRoute) GetOutboundTag() string         { return r.tag }
func (r vpnFlowRoute) GetRuleTag() string             { return "" }

func (r *vpnFlowRouter) PickRoute(ctx routing.Context) (routing.Route, error) {
	if r.configuration.balancers[ctx.GetInboundTag()] {
		return r.Router.PickRoute(ctx)
	}
	return vpnFlowRoute{ctx, r.route(ctx)}, nil
}

func vpnSubject(ctx routing.Context) (subject rules.Subject) {
	switch ctx.GetNetwork() {
	case xnet.Network_TCP:
		subject.Proto = 6
	case xnet.Network_UDP:
		subject.Proto = 17
	default:
		return subject
	}
	if ips := ctx.GetTargetIPs(); len(ips) != 0 {
		if ip, ok := netip.AddrFromSlice(ips[0]); ok {
			subject.Dst = netip.AddrPortFrom(ip.Unmap(), uint16(ctx.GetTargetPort()))
		}
	}
	return subject
}

func (r *vpnFlowRouter) route(ctx routing.Context) string {
	plan := r.configuration.plan
	subject := vpnSubject(ctx)
	if subject.Proto == 0 {
		return blockTag
	}
	if len(plan.router.appPackages) > 0 {
		ips := ctx.GetSourceIPs()
		if len(ips) == 0 || !subject.Dst.IsValid() || r.platform == nil {
			return blockTag
		}
		protocol := "tcp"
		if subject.Proto == 17 {
			protocol = "udp"
		}
		subject.AppPackage = r.platform.PackageForFlow(protocol, ips[0].String(), int32(ctx.GetSourcePort()), subject.Dst.Addr().String(), int32(ctx.GetTargetPort()))
		if subject.AppPackage == "?" {
			return blockTag
		}
	}
	result := plan.evaluateFlow(subject, ctx.GetTargetDomain())
	if result.NeedsDomain || result.Action == rules.Block {
		return blockTag
	}
	if result.Action == rules.Direct {
		return directTag
	}
	if plan.splitDNS != nil && subject.Dst.Port() == 53 && subject.Dst.Addr().String() == vpnDNS {
		return splitDNSTag
	}
	if tag := plan.tags[result.Profile]; tag != "" {
		return tag
	}
	return blockTag
}

func (plan *VPNPlan) evaluateFlow(subject rules.Subject, domain string) rules.Result {
	var result rules.Result
	if domain != "" {
		result = plan.router.rules.EvaluateDomain(subject, domain, rules.SrcNone)
	} else {
		result = plan.router.rules.EvaluateNoDomain(subject)
	}
	if subject.Dst.Port() == 53 {
		// The configured DNS uses the active VPN. A saved rule can block DNS,
		// but a direct default cannot make the resolver leave the tunnel.
		if result.Action == rules.Block && !result.NeedsDomain {
			return result
		}
		if subject.Dst.Addr().String() != vpnDNS {
			return rules.Result{Action: rules.Block, Rule: "Системный DNS"}
		}
		return rules.Result{Action: rules.Tunnel, Profile: plan.selected, Rule: "Системный DNS"}
	}
	return result
}
