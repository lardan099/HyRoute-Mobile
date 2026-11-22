package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

const journalLimit = 160

var journalMu sync.Mutex

var journalMessages = map[string]string{
	"vpn_request":       "Запрошено подключение VPN",
	"vpn_permission":    "Ожидание разрешения системы",
	"vpn_denied":        "Разрешение VPN отклонено",
	"vpn_service_error": "Система не запустила службу VPN",
	"vpn_state_error":   "Не удалось открыть хранилище VPN",
	"vpn_plan_error":    "Проверьте профиль, правила и базы GeoSite/GeoIP",
	"vpn_prepare_error": "Не удалось подготовить соединение. Проверьте адрес сервера и настройки профиля",
	"vpn_app_error":     "Не удалось применить список приложений для VPN",
	"vpn_interface":     "Настройка сетевого интерфейса VPN",
	"vpn_tun_error":     "Система не создала интерфейс VPN",
	"vpn_engine_error":  "Сетевое ядро не запустилось",
	"vpn_running":       "Интерфейс VPN включён",
	"vpn_stop":          "Запрошено отключение VPN",
	"vpn_revoke":        "Система отозвала VPN",
	"vpn_stopped":       "VPN отключён",
	"vpn_system_error":  "Не удалось открыть или сохранить системные настройки VPN",
	"probe_start":       "Начата проверка задержки",
	"probe_done":        "Проверка задержки завершена",
	"probe_cancel":      "Проверка задержки отменена",
}

type journalEntry struct {
	At    int64  `json:"at"`
	Event string `json:"event"`
}

// RecordVPNEvent accepts a fixed event code only. Never persist raw errors,
// destination addresses or subscription data to the journal.
func RecordVPNEvent(path, event string) {
	if path == "" || journalMessages[event] == "" {
		return
	}
	journalMu.Lock()
	defer journalMu.Unlock()
	entries := append(readJournal(path), journalEntry{time.Now().UnixMilli(), event})
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
			lines = append(lines, time.UnixMilli(entry.At).Format("02.01 15:04:05")+"  "+message)
		}
	}
	data, _ := json.Marshal(lines)
	return string(data)
}
