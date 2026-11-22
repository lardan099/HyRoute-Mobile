package mobile

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

const journalLimit = 160

var journalMu sync.Mutex

var journalMessages = map[string]string{
	"vpn_request":             "Запрошено подключение VPN",
	"vpn_permission":          "Ожидание разрешения системы",
	"vpn_denied":              "Разрешение VPN отклонено",
	"vpn_service_error":       "Система не запустила службу VPN",
	"vpn_state_error":         "Не удалось открыть хранилище VPN",
	"vpn_plan_error":          "Проверьте профиль, правила и базы GeoSite/GeoIP",
	"vpn_prepare_error":       "Не удалось подготовить соединение. Проверьте адрес сервера и настройки профиля",
	"vpn_app_error":           "Не удалось применить список приложений для VPN",
	"vpn_interface":           "Настройка сетевого интерфейса VPN",
	"vpn_tun_error":           "Система не создала интерфейс VPN",
	"vpn_engine_error":        "Сетевое ядро не запустилось",
	"vpn_running":             "Интерфейс VPN включён",
	"vpn_stop":                "Запрошено отключение VPN",
	"vpn_revoke":              "Система отозвала VPN",
	"vpn_stopped":             "VPN отключён",
	"vpn_system_error":        "Не удалось открыть или сохранить системные настройки VPN",
	"vpn_handoff":             "Запуск передан iOS",
	"vpn_provider_start":      "VPN-расширение получило запрос на запуск",
	"vpn_provider_missing":    "В установленном приложении отсутствует расширение Packet Tunnel",
	"vpn_preferences_stale":   "iOS обновила настройки VPN. Повторное чтение конфигурации",
	"vpn_start_failed":        "iOS отключила VPN во время запуска",
	"vpn_start_timeout":       "VPN не запустился за 35 секунд",
	"vpn_cancelled":           "Запуск VPN отменён",
	"vpn_disconnect":          "iOS отключила активный VPN",
	"vpn_ios_error":           "Последняя ошибка VPN от iOS",
	"vpn_extension_retry":     "iOS сообщила о сбое расширения. Повторный запуск VPN",
	"vpn_options_missing":     "iOS не передала настройки VPN-расширению",
	"vpn_profile_missing":     "Нет доступного профиля VPN",
	"vpn_rules_error":         "Расширение не смогло применить локальные правила",
	"vpn_geo_error":           "Расширению недоступна база или категория GeoSite/GeoIP",
	"vpn_reference_missing":   "Правило или цепочка ссылается на профиль, отсутствующий в подписке",
	"vpn_profile_unsupported": "В профиле VPN указаны неподдерживаемые параметры",
	"probe_start":             "Начата проверка задержки",
	"probe_done":              "Проверка задержки завершена",
	"probe_cancel":            "Проверка задержки отменена",
}

type journalEntry struct {
	At     int64  `json:"at"`
	Event  string `json:"event"`
	Code   *int32 `json:"code,omitempty"`
	Source string `json:"source,omitempty"`
}

// RecordVPNEvent accepts a fixed event code only. Never persist raw errors,
// destination addresses or subscription data to the journal.
func RecordVPNEvent(path, event string) {
	if path == "" || journalMessages[event] == "" {
		return
	}
	appendJournal(path, journalEntry{At: time.Now().UnixMilli(), Event: event})
}

// RecordVPNError stores a numeric error code from a known iOS component.
func RecordVPNError(path, event, source string, code int32) {
	if path == "" || journalMessages[event] == "" {
		return
	}
	switch source {
	case "NEVPNErrorDomain", "NEVPNConnectionErrorDomain", "PacketTunnel":
	default:
		source = "iOS"
	}
	appendJournal(path, journalEntry{At: time.Now().UnixMilli(), Event: event, Code: &code, Source: source})
}

func appendJournal(path string, entry journalEntry) {
	journalMu.Lock()
	defer journalMu.Unlock()
	entries := append(readJournal(path), entry)
	entries = entries[max(0, len(entries)-journalLimit):]
	data, err := json.Marshal(entries)
	if err != nil {
		return
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".journal-*")
	if err != nil {
		return
	}
	defer os.Remove(file.Name())
	_, err = file.Write(data)
	closeErr := file.Close()
	if err == nil && closeErr == nil {
		_ = os.Rename(file.Name(), path)
	}
}

func readJournal(path string) []journalEntry {
	if path == "" {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var entries []journalEntry
	if json.Unmarshal(data, &entries) != nil {
		return nil
	}
	return entries
}

// VPNJournal combines app and extension events, newest first. The two paths
// have separate owners and never share a writer across processes.
func VPNJournal(appPath, tunnelPath string) string {
	entries := append(readJournal(appPath), readJournal(tunnelPath)...)
	slices.SortStableFunc(entries, func(a, b journalEntry) int { return time.UnixMilli(b.At).Compare(time.UnixMilli(a.At)) })
	lines := make([]string, 0, min(journalLimit, len(entries)))
	for _, entry := range entries[:min(journalLimit, len(entries))] {
		if message := journalMessages[entry.Event]; message != "" {
			if entry.Code != nil {
				message += fmt.Sprintf(" (%s, код %d)", entry.Source, *entry.Code)
			}
			lines = append(lines, time.UnixMilli(entry.At).Format("02.01 15:04:05")+"  "+message)
		}
	}
	data, _ := json.Marshal(lines)
	return string(data)
}
