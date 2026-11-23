package mobile

import (
	"encoding/json"
	"errors"
	"strings"
	"syscall"
	"testing"
)

func TestVPNFlowLogIsOptInBoundedAndCanBeCleared(t *testing.T) {
	journal := new(trafficJournal)
	session := &VPNSession{traffic: journal}
	journal.append(trafficEvent{Flow: 42, Destination: "private.test"})
	if snapshot := session.TrafficEvents(); snapshot != "[]" {
		t.Fatalf("logged with recording off: %s", snapshot)
	}
	session.SetTrafficLogging(true)
	for range trafficJournalCapacity + 5 {
		journal.append(trafficEvent{Flow: 42, Destination: "demo.test:443\n", Error: trafficError(syscall.ECONNREFUSED)})
	}
	var events []trafficEvent
	if err := json.Unmarshal([]byte(session.TrafficEvents()), &events); err != nil {
		t.Fatal(err)
	}
	if len(events) != trafficJournalCapacity || events[0].ID != trafficJournalCapacity+5 ||
		events[trafficJournalCapacity-1].ID != 6 || events[0].Destination != "demo.test:443" ||
		events[0].Error != "В соединении отказано" {
		t.Fatalf("incorrect ring eviction or formatting, newest event %+v, count %d", events[0], len(events))
	}
	if reason := trafficError(errors.New("raw diagnostic with a secret URI")); strings.Contains(reason, "secret") {
		t.Fatal("raw transport error leaked")
	}
	session.ClearTrafficEvents()
	if snapshot := session.TrafficEvents(); snapshot != "[]" {
		t.Fatalf("journal did not clear: %s", snapshot)
	}
}
