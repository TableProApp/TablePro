package hana

import (
	"encoding/json"
	"testing"
)

func decodeFailure(t *testing.T, encoded []byte) bridgeError {
	t.Helper()
	if encoded == nil {
		t.Fatal("got no failure")
	}
	var failure bridgeError
	if err := json.Unmarshal(encoded, &failure); err != nil {
		t.Fatalf("failure %q is not JSON: %v", encoded, err)
	}
	return failure
}

func assertFailureKind(t *testing.T, encoded []byte, kind string) {
	t.Helper()
	if failure := decodeFailure(t, encoded); failure.Kind != kind {
		t.Fatalf("kind = %q (%s); want %q", failure.Kind, encoded, kind)
	}
}

func registeredSession(t *testing.T, bridge *Bridge, id uint64) *session {
	t.Helper()
	entry, failure := bridge.sessions.lookup(id)
	if failure != nil {
		t.Fatalf("session %d is not registered: %v", id, failure)
	}
	return entry
}

func TestOpenAnswersAnInvalidConfigurationAsJSON(t *testing.T) {
	bridge := NewBridge()
	id, failure := bridge.Open([]byte(`{"host":"","port":30015,"username":"DBADMIN","tlsMode":"disabled"}`))
	if id != 0 {
		t.Fatalf("id = %d; want 0 for a refused configuration", id)
	}
	decoded := decodeFailure(t, failure)
	if decoded.Kind != kindConfiguration || decoded.Message != "host" {
		t.Fatalf("failure = %+v; want the configuration field host", decoded)
	}
}

func TestOpenAnswersMalformedJSONAsAnInternalFailure(t *testing.T) {
	_, failure := NewBridge().Open([]byte(`{"host":`))
	assertFailureKind(t, failure, kindInternal)
}

func TestEveryCallOnAnUnknownSessionAnswersClosedAsJSON(t *testing.T) {
	bridge := NewBridge()
	result, failure := bridge.Connect(7, 1)
	if result != nil {
		t.Fatalf("connect result = %q; want none", result)
	}
	assertFailureKind(t, failure, kindClosed)
	result, failure = bridge.Execute(7, 2, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	if result != nil {
		t.Fatalf("execute result = %q; want none", result)
	}
	assertFailureKind(t, failure, kindClosed)
	result, failure = bridge.Explain(7, 3, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	if result != nil {
		t.Fatalf("explain result = %q; want none", result)
	}
	assertFailureKind(t, failure, kindClosed)
	assertFailureKind(t, bridge.Ping(7, 4), kindClosed)
	bridge.Cancel(7, 0)
	bridge.Close(7)
}

func TestBridgesKeepTheirOwnSessions(t *testing.T) {
	owner := NewBridge()
	stranger := NewBridge()
	id, failure := owner.Open(unreachableConfig(1))
	if failure != nil {
		t.Fatalf("open failed: %s", failure)
	}
	t.Cleanup(func() { owner.Close(id) })
	assertFailureKind(t, stranger.Ping(id, 1), kindClosed)
	stranger.Close(id)
	stranger.CloseAll()
	if entry := registeredSession(t, owner, id); entry.currentState() != sessionOpened {
		t.Fatalf("state = %v; another bridge's close reached this session", entry.currentState())
	}
}

func TestCloseAllClosesEverySessionAndNeverReusesTheirIDs(t *testing.T) {
	bridge := NewBridge()
	first, failure := bridge.Open(unreachableConfig(1))
	if failure != nil {
		t.Fatalf("open failed: %s", failure)
	}
	second, failure := bridge.Open(unreachableConfig(1))
	if failure != nil {
		t.Fatalf("open failed: %s", failure)
	}
	entries := []*session{registeredSession(t, bridge, first), registeredSession(t, bridge, second)}
	bridge.CloseAll()
	for _, entry := range entries {
		if entry.currentState() != sessionClosed || !entry.dialer.isSevered() {
			t.Fatalf("state=%v severed=%v; want a closed, severed session", entry.currentState(), entry.dialer.isSevered())
		}
	}
	assertFailureKind(t, bridge.Ping(first, 1), kindClosed)
	assertFailureKind(t, bridge.Ping(second, 1), kindClosed)
	third, failure := bridge.Open(unreachableConfig(1))
	if failure != nil {
		t.Fatalf("open failed: %s", failure)
	}
	t.Cleanup(func() { bridge.Close(third) })
	if third <= second {
		t.Fatalf("id %d reused after %d", third, second)
	}
	bridge.CloseAll()
	bridge.CloseAll()
}

func TestInternalFailureIsABridgeErrorOfKindInternal(t *testing.T) {
	decoded := decodeFailure(t, InternalFailure("unknown opcode 9"))
	if decoded.Kind != kindInternal || decoded.Message != "unknown opcode 9" {
		t.Fatalf("failure = %+v; want kind internal with the message", decoded)
	}
}
