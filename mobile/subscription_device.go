package mobile

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strings"
	"sync/atomic"
)

type subscriptionDevice struct {
	version   string
	seed      string
	os        string
	osVersion string
}

var currentSubscriptionDevice atomic.Pointer[subscriptionDevice]

// ConfigureSubscriptionDevice uses an installation secret to identify the
// device to subscription providers without sending a hardware identifier.
func ConfigureSubscriptionDevice(version, seed, os, osVersion string) {
	currentSubscriptionDevice.Store(&subscriptionDevice{version, seed, os, osVersion})
}

func (d *subscriptionDevice) userAgent() string {
	if d != nil && d.version != "" {
		return "HyRoute/" + d.version
	}
	return "HyRoute"
}

func (d *subscriptionDevice) setHeaders(request *http.Request) {
	request.Header.Set("User-Agent", d.userAgent())
	if d == nil || d.seed == "" {
		return
	}
	mac := hmac.New(sha256.New, []byte(d.seed))
	_, _ = mac.Write([]byte("HyRoute subscription device\x00" + strings.ToLower(request.URL.Hostname())))
	request.Header.Set("X-Hwid", hex.EncodeToString(mac.Sum(nil)[:16]))
	if d.os != "" {
		request.Header.Set("X-Device-Os", d.os)
	}
	if d.osVersion != "" {
		request.Header.Set("X-Ver-Os", d.osVersion)
	}
}
