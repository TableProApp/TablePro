package hana

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"testing"
	"time"
)

func sessionConfig(port int, tlsMode string, extra string) []byte {
	return timedSessionConfig(port, tlsMode, 10, extra)
}

func timedSessionConfig(port int, tlsMode string, timeoutSeconds float64, extra string) []byte {
	return []byte(fmt.Sprintf(`{"host":"127.0.0.1","port":%d,"username":"DBADMIN","password":"secret","tlsMode":%q,"connectTimeoutSeconds":%g%s}`, port, tlsMode, timeoutSeconds, extra))
}

func closedPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	return port
}

type connectOutcome struct {
	result  []byte
	failure *bridgeError
	elapsed time.Duration
}

func connectInBackground(id uint64, operationID uint64) <-chan connectOutcome {
	outcome := make(chan connectOutcome, 1)
	go func() {
		started := time.Now()
		result, failure := testBridge.connectSession(id, operationID)
		outcome <- connectOutcome{result: result, failure: failure, elapsed: time.Since(started)}
	}()
	return outcome
}

func awaitConnect(t *testing.T, outcome <-chan connectOutcome) connectOutcome {
	t.Helper()
	select {
	case result := <-outcome:
		return result
	case <-time.After(8 * time.Second):
		t.Fatal("connect did not return")
		return connectOutcome{}
	}
}

func TestConnectToAClosedPortIsAConnectFailure(t *testing.T) {
	id := openTestSession(t, sessionConfig(closedPort(t), tlsModeDisabled, ""))
	_, failure := testBridge.connectSession(id, 1)
	assertKind(t, failure, kindConnect)
	_, failure = testBridge.executeOnSession(id, 2, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindConnectionLost)
}

func TestConnectTimeoutEndsAConnectToASilentServer(t *testing.T) {
	server := newSilentServer(t)
	id := openTestSession(t, timedSessionConfig(server.port(), tlsModeDisabled, 0.3, ""))
	outcome := awaitConnect(t, connectInBackground(id, 1))
	assertKind(t, outcome.failure, kindTimeout)
	server.waitForClientHangUp(t)
}

func TestCancellingTheConnectOperationStopsIt(t *testing.T) {
	for _, operationToCancel := range []uint64{1, 0} {
		server := newSilentServer(t)
		id := openTestSession(t, sessionConfig(server.port(), tlsModeDisabled, ""))
		outcome := connectInBackground(id, 1)
		waitFor(t, func() bool { return server.accepted.Load() == 1 })
		time.Sleep(50 * time.Millisecond)
		testBridge.cancelOnSession(id, operationToCancel)
		result := awaitConnect(t, outcome)
		assertKind(t, result.failure, kindCancelled)
		if result.elapsed > 5*time.Second {
			t.Fatalf("cancel took %v", result.elapsed)
		}
		server.waitForClientHangUp(t)
		_, failure := testBridge.executeOnSession(id, 2, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
		assertKind(t, failure, kindConnectionLost)
	}
}

func TestConnectCancelledBeforeItStartsNeverDials(t *testing.T) {
	server := newSilentServer(t)
	id := openTestSession(t, sessionConfig(server.port(), tlsModeDisabled, ""))
	testBridge.cancelOnSession(id, 1)
	_, failure := testBridge.connectSession(id, 1)
	assertKind(t, failure, kindCancelled)
	time.Sleep(50 * time.Millisecond)
	if accepted := server.accepted.Load(); accepted != 0 {
		t.Fatalf("a connect cancelled before it started dialed %d times", accepted)
	}
}

func TestClosingDuringConnectAnswersClosedPromptly(t *testing.T) {
	server := newSilentServer(t)
	id, failure := testBridge.openSession(sessionConfig(server.port(), tlsModeDisabled, ""))
	if failure != nil {
		t.Fatal(failure)
	}
	outcome := connectInBackground(id, 1)
	waitFor(t, func() bool { return server.accepted.Load() == 1 })
	started := time.Now()
	testBridge.closeSession(id)
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("closing the session blocked for %v", elapsed)
	}
	result := awaitConnect(t, outcome)
	assertKind(t, result.failure, kindClosed)
	server.waitForClientHangUp(t)
	_, failure = testBridge.executeOnSession(id, 2, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindClosed)
}

func TestEverySessionSeversAfterTheExportedGrace(t *testing.T) {
	id := openTestSession(t, unreachableConfig(closedPort(t)))
	entry, failure := testBridge.sessions.lookup(id)
	if failure != nil {
		t.Fatal(failure)
	}
	if entry.slot.severGrace != ForcedSeverGrace {
		t.Fatalf("the session severs after %v; want the exported ForcedSeverGrace %v", entry.slot.severGrace, ForcedSeverGrace)
	}
}

func TestStatementsBeforeConnectAnswerConnectionLost(t *testing.T) {
	id := openTestSession(t, unreachableConfig(1))
	_, failure := testBridge.executeOnSession(id, 1, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindConnectionLost)
	_, failure = testBridge.explainOnSession(id, 2, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindConnectionLost)
	assertKind(t, testBridge.pingSession(id, 3), kindConnectionLost)
}

func TestConnectThroughGoHdbReportsTLSFailures(t *testing.T) {
	plaintext := startPlaintextServer(t, func(conn net.Conn) {
		buffer := make([]byte, 512)
		_, _ = conn.Read(buffer)
		_, _ = conn.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n"))
	})
	id := openTestSession(t, sessionConfig(plaintext, tlsModeRequired, ""))
	_, failure := testBridge.connectSession(id, 1)
	assertTLSCode(t, failure, tlsFailurePlaintextServer)

	authority := newTestAuthority(t)
	certificate, _, _ := authority.issue(t, 2, x509.ExtKeyUsageServerAuth, "hana.internal")
	server := newTLSTestServer(t, certificate, nil)
	untrusted := openTestSession(t, sessionConfig(server.port(), tlsModeVerifyCA, ""))
	_, failure = testBridge.connectSession(untrusted, 1)
	assertTLSCode(t, failure, tlsFailureUntrusted)

	mismatch := openTestSession(t, sessionConfig(server.port(), tlsModeVerifyIdentity, fmt.Sprintf(`,"caCertificatePath":%q`, authority.pemPath)))
	_, failure = testBridge.connectSession(mismatch, 1)
	assertTLSCode(t, failure, tlsFailureHostnameMismatch)

	hangingUp := startHangingUpTLSServer(t, certificate)
	trusted := openTestSession(t, sessionConfig(hangingUp, tlsModeVerifyCA, fmt.Sprintf(`,"caCertificatePath":%q`, authority.pemPath)))
	_, failure = testBridge.connectSession(trusted, 1)
	assertKind(t, failure, kindConnect)
}

func startHangingUpTLSServer(t *testing.T, certificate tls.Certificate) int {
	t.Helper()
	listener, err := tls.Listen("tcp4", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{certificate}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer func() { _ = conn.Close() }()
				if secured, ok := conn.(*tls.Conn); ok {
					_ = secured.Handshake()
				}
			}()
		}
	}()
	return listener.Addr().(*net.TCPAddr).Port
}

func TestConnectTwiceIsRefused(t *testing.T) {
	id := openTestSession(t, sessionConfig(closedPort(t), tlsModeDisabled, ""))
	_, failure := testBridge.connectSession(id, 1)
	assertKind(t, failure, kindConnect)
	_, failure = testBridge.connectSession(id, 2)
	assertKind(t, failure, kindConnectionLost)
}
