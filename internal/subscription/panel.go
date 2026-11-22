package subscription

import (
	"encoding/base64"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	MaxInfoHeader = 1024 // subscription-userinfo longer than this is ignored
	MaxLinkLen    = 2048
	MaxTitleRunes = 100
	MaxInfoValue  = int64(1) << 62
	// MillisecondsExpire: an expire at or above it is in milliseconds (some panels).
	// In seconds it would be after the year 5138, so an expire still at or
	// above it after the division is invalid: every date shown fits in four
	// digits in any time zone, and the canonical form reads back the same.
	MillisecondsExpire = int64(1e11)
	// minMsExpire: a divided expire below it (2000-01-01) was a far-future
	// seconds value meaning "never" (such as 253402300799, 31.12.9999), not
	// milliseconds: it is skipped rather than shown as a 1970s date.
	minMsExpire = int64(946684800)
)

// UserInfo is a parsed subscription-userinfo header.
type UserInfo struct {
	Upload, Download, Total, Expire             int64
	HasUpload, HasDownload, HasTotal, HasExpire bool
}

// ParseUserInfo reads "upload=1; download=2; total=3; expire=4". Separators
// ';' or ','; keys case-insensitive, surrounding spaces ignored; values are
// non-negative integers (a float such as "1.5e9" or "1712345678.0" is
// truncated); the first valid occurrence of a key wins; unknown keys, empty,
// negative, non-finite or > MaxInfoValue values are skipped. expire ≥ 1e11
// is milliseconds; an expire still ≥ 1e11 after that, or before 2000 (a
// far-future seconds value), is skipped. ok is false
// when s is longer than MaxInfoHeader or no key was recognised.
func ParseUserInfo(s string) (u UserInfo, ok bool) {
	if len(s) > MaxInfoHeader {
		return UserInfo{}, false
	}
	for part := range strings.FieldsFuncSeq(s, func(r rune) bool { return r == ';' || r == ',' }) {
		k, v, found := strings.Cut(part, "=")
		if !found {
			continue
		}
		n, valid := infoValue(strings.TrimSpace(v))
		if !valid {
			continue
		}
		switch strings.ToLower(strings.TrimSpace(k)) {
		case "upload":
			if !u.HasUpload {
				u.Upload, u.HasUpload = n, true
			}
		case "download":
			if !u.HasDownload {
				u.Download, u.HasDownload = n, true
			}
		case "total":
			if !u.HasTotal {
				u.Total, u.HasTotal = n, true
			}
		case "expire":
			if n >= MillisecondsExpire {
				n /= 1000
				if n < minMsExpire {
					continue
				}
			}
			if !u.HasExpire && n < MillisecondsExpire {
				u.Expire, u.HasExpire = n, true
			}
		}
	}
	return u, u.HasUpload || u.HasDownload || u.HasTotal || u.HasExpire
}

// infoValue reads one value: an integer in [0, MaxInfoValue], or a finite
// float in that range, truncated.
func infoValue(v string) (int64, bool) {
	if v == "" {
		return 0, false
	}
	if n, err := strconv.ParseInt(v, 10, 64); err == nil {
		return n, n >= 0 && n <= MaxInfoValue
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || math.IsNaN(f) || f < 0 || f > float64(MaxInfoValue) {
		return 0, false
	}
	n := int64(f)
	return n, n >= 0 && n <= MaxInfoValue
}

// String is the canonical form stored in Subscription.UserInfo (v1.0.0's
// trafficText reads it): "upload=…; download=…; total=…; expire=…", present
// keys only, in this order. The raw total is kept (≥ 1 PiB is interpreted
// as unlimited only in the view).
func (u UserInfo) String() string {
	var parts []string
	add := func(has bool, k string, v int64) {
		if has {
			parts = append(parts, k+"="+strconv.FormatInt(v, 10))
		}
	}
	add(u.HasUpload, "upload", u.Upload)
	add(u.HasDownload, "download", u.Download)
	add(u.HasTotal, "total", u.Total)
	add(u.HasExpire, "expire", u.Expire)
	return strings.Join(parts, "; ")
}

// NormalizeUserInfo returns the canonical form of a header, or "".
func NormalizeUserInfo(raw string) string {
	u, ok := ParseUserInfo(raw)
	if !ok {
		return ""
	}
	return u.String()
}

// PanelInfo holds subscription metadata advertised by the provider.
type PanelInfo struct {
	Title       string `json:"title,omitempty"`
	UserInfo    string `json:"userInfo,omitempty"`
	UpdateHours int    `json:"updateHours,omitempty"`
	Support     string `json:"support,omitempty"`
}

// CleanTitle drops control characters (whitespace ones become spaces),
// format characters (bidi embeddings, overrides and isolates, marks,
// zero-width characters, BOM, soft hyphen…) and private-use characters;
// drops invalid UTF-8; collapses runs of spaces, trims and caps at
// MaxTitleRunes. The title becomes the default subscription name, shown on
// Home, in the nav, diagnostics, the CLI and «Правила текстом» exports, so
// it must not reorder or hide surrounding text.
func CleanTitle(s string) string {
	var b strings.Builder
	n, space := 0, false
	for _, r := range strings.ToValidUTF8(s, "") {
		if unicode.IsSpace(r) {
			space = b.Len() > 0
			continue
		}
		if unicode.In(r, unicode.Cc, unicode.Cf, unicode.Co) || r == utf8.RuneError {
			continue
		}
		if n >= MaxTitleRunes {
			break
		}
		if space {
			b.WriteByte(' ')
			n++
			space = false
			if n >= MaxTitleRunes {
				break
			}
		}
		b.WriteRune(r)
		n++
	}
	return strings.TrimSpace(b.String())
}

// ParseUpdateHours reads profile-update-interval (whole hours 1..8760; 0
// otherwise).
func ParseUpdateHours(s string) int {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || n < 1 || n > 8760 {
		return 0
	}
	return n
}

// ReadPanelHeaders reads the panel's headers of a 200 answer. Each raw value
// longer than its bound is dropped before any processing (the title is
// bounded before decoding); Clean then normalises them.
func ReadPanelHeaders(h http.Header) PanelInfo {
	var r PanelInfo
	if t := h.Get("Profile-Title"); len(t) <= 4*MaxInfoHeader {
		r.Title = decodeTitle(t)
	}
	if u := h.Get("Subscription-Userinfo"); len(u) <= MaxInfoHeader {
		r.UserInfo = u
	}
	if u := h.Get("Profile-Update-Interval"); len(u) <= 16 {
		r.UpdateHours = ParseUpdateHours(u)
	}
	if u := h.Get("Support-Url"); len(u) <= MaxLinkLen {
		r.Support = u
	}
	return r
}

// Clean normalises provider data.

func (r PanelInfo) Clean() PanelInfo {
	r.Title = CleanTitle(r.Title)
	r.UserInfo = NormalizeUserInfo(r.UserInfo)
	if r.UpdateHours < 1 || r.UpdateHours > 8760 {
		r.UpdateHours = 0
	}
	r.Support = SafeLink(r.Support)
	return r
}

// SafeLink returns the canonical form of a panel link that may be shown and
// opened: an absolute http(s) URL with a host, no user info, at most
// MaxLinkLen bytes, no whitespace, control or format characters or any of
// `"<>\^`{|}`. "" otherwise. It re-serialises through url.URL.String().
func SafeLink(raw string) string {
	if raw == "" || len(raw) > MaxLinkLen || !utf8.ValidString(raw) {
		return ""
	}
	for _, r := range raw {
		if unicode.IsSpace(r) || unicode.In(r, unicode.Cc, unicode.Cf, unicode.Co) || strings.ContainsRune("\"<>\\^`{|}", r) {
			return ""
		}
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Opaque != "" || u.User != nil || u.Hostname() == "" {
		return ""
	}
	out := u.String()
	if len(out) > MaxLinkLen {
		return ""
	}
	return out
}

// decodeTitle handles "base64:..." titles used by common panels.
func decodeTitle(s string) string {
	if rest, ok := strings.CutPrefix(s, "base64:"); ok {
		if b, err := base64.StdEncoding.DecodeString(rest); err == nil {
			return string(b)
		}
	}
	return s
}
