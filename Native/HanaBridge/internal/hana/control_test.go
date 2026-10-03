package hana

import (
	"testing"
	"time"
)

func connectedTestSession(t *testing.T, port int, connectionID int64) *session {
	t.Helper()
	id := openTestSession(t, sessionConfig(port, tlsModeDisabled, ""))
	entry, failure := testBridge.sessions.lookup(id)
	if failure != nil {
		t.Fatal(failure)
	}
	entry.mu.Lock()
	entry.state = sessionConnected
	entry.connectionID = connectionID
	entry.mu.Unlock()
	return entry
}

func TestCancelStatementNamesTheServerConnection(t *testing.T) {
	if got := cancelSessionStatement(200123); got != "ALTER SYSTEM CANCEL SESSION '200123'" {
		t.Fatalf("cancel statement = %q", got)
	}
}

func TestFailedCancelClosesTheSocketsAndLosesTheSession(t *testing.T) {
	entry := connectedTestSession(t, closedPort(t), 200123)
	started := time.Now()
	entry.interruptStatement(stopCancelled)
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("a refused control connection took %v", elapsed)
	}
	if entry.currentState() != sessionLost || !entry.dialer.isSevered() {
		t.Fatalf("state=%v severed=%v; want a lost, severed session", entry.currentState(), entry.dialer.isSevered())
	}
}

func TestCancelWithoutAServerConnectionIDLosesTheSession(t *testing.T) {
	server := newSilentServer(t)
	entry := connectedTestSession(t, server.port(), 0)
	entry.interruptStatement(stopTimedOut)
	if entry.currentState() != sessionLost {
		t.Fatalf("state = %v; want lost", entry.currentState())
	}
	if accepted := server.accepted.Load(); accepted != 0 {
		t.Fatalf("a cancel with no connection id dialed %d control connections", accepted)
	}
}

func TestClosingInterruptSendsNoCancel(t *testing.T) {
	server := newSilentServer(t)
	entry := connectedTestSession(t, server.port(), 200123)
	entry.interruptStatement(stopClosed)
	time.Sleep(50 * time.Millisecond)
	if accepted := server.accepted.Load(); accepted != 0 || entry.currentState() != sessionConnected {
		t.Fatalf("closing interrupt dialed %d times, state %v", accepted, entry.currentState())
	}
}
