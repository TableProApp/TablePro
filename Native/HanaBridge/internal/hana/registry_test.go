package hana

import (
	"fmt"
	"testing"
)

var testBridge = NewBridge()

func unreachableConfig(port int) []byte {
	return []byte(fmt.Sprintf(`{"host":"127.0.0.1","port":%d,"username":"DBADMIN","password":"secret","tlsMode":"disabled","connectTimeoutSeconds":2}`, port))
}

func openTestSession(t *testing.T, config []byte) uint64 {
	t.Helper()
	id, failure := testBridge.openSession(config)
	if failure != nil {
		t.Fatalf("openSession: %v", failure)
	}
	t.Cleanup(func() { testBridge.closeSession(id) })
	return id
}

func assertKind(t *testing.T, failure *bridgeError, kind string) {
	t.Helper()
	if failure == nil {
		t.Fatalf("got no error; want kind %q", kind)
	}
	if failure.Kind != kind {
		t.Fatalf("kind = %q (%v); want %q", failure.Kind, failure, kind)
	}
}

func TestUnknownSessionIDAnswersClosedEverywhere(t *testing.T) {
	const unknown = 1 << 60
	_, failure := testBridge.connectSession(unknown, 1)
	assertKind(t, failure, kindClosed)
	_, failure = testBridge.executeOnSession(unknown, 1, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindClosed)
	_, failure = testBridge.explainOnSession(unknown, 1, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindClosed)
	assertKind(t, testBridge.pingSession(unknown, 1), kindClosed)
	testBridge.cancelOnSession(unknown, 0)
	testBridge.closeSession(unknown)
}

func TestSessionIDZeroIsNeverIssued(t *testing.T) {
	_, failure := testBridge.executeOnSession(0, 1, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindClosed)
	id := openTestSession(t, unreachableConfig(1))
	if id == 0 {
		t.Fatal("openSession issued id 0")
	}
}

func TestClosedSessionAnswersClosedAndItsIDIsNeverReused(t *testing.T) {
	first := openTestSession(t, unreachableConfig(1))
	testBridge.closeSession(first)
	testBridge.closeSession(first)
	_, failure := testBridge.executeOnSession(first, 1, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindClosed)
	_, failure = testBridge.connectSession(first, 2)
	assertKind(t, failure, kindClosed)
	assertKind(t, testBridge.pingSession(first, 3), kindClosed)
	testBridge.cancelOnSession(first, 0)

	second := openTestSession(t, unreachableConfig(1))
	third := openTestSession(t, unreachableConfig(1))
	if second <= first || third <= second {
		t.Fatalf("ids %d, %d, %d are not strictly increasing", first, second, third)
	}
}

func TestRegistryKeepsSessionsApart(t *testing.T) {
	registry := newSessionRegistry()
	one := &session{}
	two := &session{}
	firstID := registry.register(one)
	secondID := registry.register(two)
	found, failure := registry.lookup(secondID)
	if failure != nil || found != two {
		t.Fatalf("lookup(%d) = %p, %v; want the second session", secondID, found, failure)
	}
	removed, ok := registry.remove(firstID)
	if !ok || removed != one {
		t.Fatalf("remove(%d) = %p, %v; want the first session", firstID, removed, ok)
	}
	if _, ok := registry.remove(firstID); ok {
		t.Fatal("a removed id was removed twice")
	}
	_, failure = registry.lookup(firstID)
	assertKind(t, failure, kindClosed)
	if thirdID := registry.register(one); thirdID <= secondID {
		t.Fatalf("id %d reused after %d", thirdID, secondID)
	}
}
