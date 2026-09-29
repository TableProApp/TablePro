package hana

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"syscall"
	"testing"
)

type fakeServerError struct {
	code     int
	position int
	text     string
}

func (e fakeServerError) Error() string {
	return fmt.Sprintf("SQL Error %d - %s", e.code, e.text)
}
func (e fakeServerError) StmtNo() int     { return 0 }
func (e fakeServerError) Code() int       { return e.code }
func (e fakeServerError) Position() int   { return e.position }
func (e fakeServerError) Level() int      { return 1 }
func (e fakeServerError) Text() string    { return e.text }
func (e fakeServerError) IsWarning() bool { return false }
func (e fakeServerError) IsError() bool   { return true }
func (e fakeServerError) IsFatal() bool   { return false }

var cancelledByServer = fakeServerError{code: hanaStatementCancelledCode, text: "current operation cancelled by request and transaction rolled back"}

func TestServerErrorsKeepCodePositionAndText(t *testing.T) {
	failure := classifyError(fmt.Errorf("wrapped: %w", fakeServerError{code: 259, position: 14, text: "invalid table name"}))
	assertKind(t, failure, kindServer)
	if failure.Code != 259 || failure.Position != 14 || failure.Message != "invalid table name" {
		t.Fatalf("failure = %+v", failure)
	}
	lenient := classifyError(fakeServerError{code: 7, text: "bad \xed\xa0\x80 text"})
	if lenient.Message != "bad \uFFFD text" {
		t.Fatalf("server text = %q; want the invalid CESU-8 replaced", lenient.Message)
	}
}

func TestStatementCancelledAfterOurInterruptIsCancelledOrTimeout(t *testing.T) {
	assertKind(t, resolveFailure(sessionConnected, stopCancelled, cancelledByServer), kindCancelled)
	assertKind(t, resolveFailure(sessionConnected, stopTimedOut, cancelledByServer), kindTimeout)
	assertKind(t, resolveFailure(sessionConnected, stopCancelled, fmt.Errorf("sql: Scan error: %w", errOperationStopped)), kindCancelled)
	assertKind(t, resolveFailure(sessionConnected, stopTimedOut, errOperationStopped), kindTimeout)
	notOurs := resolveFailure(sessionConnected, stopNone, cancelledByServer)
	assertKind(t, notOurs, kindServer)
	if notOurs.Code != hanaStatementCancelledCode {
		t.Fatalf("a cancel we did not send lost its code: %+v", notOurs)
	}
	assertKind(t, resolveFailure(sessionConnected, stopCancelled, fakeServerError{code: 259}), kindServer)
}

func TestConnectionFailuresAreConnectionLost(t *testing.T) {
	failures := []error{
		driver.ErrBadConn,
		fmt.Errorf("%w: %w", driver.ErrBadConn, io.EOF),
		sql.ErrConnDone,
		io.ErrUnexpectedEOF,
		net.ErrClosed,
		errDialerSevered,
		errPingUnanswered,
		&net.OpError{Op: "read", Net: "tcp", Err: syscall.ECONNRESET},
	}
	for _, failure := range failures {
		assertKind(t, resolveFailure(sessionConnected, stopNone, failure), kindConnectionLost)
		assertKind(t, resolveFailure(sessionConnected, stopCancelled, failure), kindConnectionLost)
	}
	message := classifyError(fmt.Errorf("%w: %w", driver.ErrBadConn, io.EOF)).Message
	if message != "EOF" {
		t.Fatalf("message = %q; want the bad connection prefix stripped", message)
	}
}

func TestLostSessionAnswersConnectionLostForServerErrors(t *testing.T) {
	assertKind(t, resolveFailure(sessionLost, stopCancelled, cancelledByServer), kindConnectionLost)
	assertKind(t, resolveFailure(sessionLost, stopNone, fakeServerError{code: 259}), kindConnectionLost)
}

func TestClosedAndDroppedOperations(t *testing.T) {
	assertKind(t, resolveFailure(sessionClosed, stopNone, driver.ErrBadConn), kindClosed)
	assertKind(t, resolveFailure(sessionConnected, stopNone, errSlotClosed), kindClosed)
	assertKind(t, resolveFailure(sessionConnected, stopNone, errOperationDroppedWhileQueued), kindCancelled)
	assertKind(t, resolveFailure(sessionLost, stopNone, errOperationDroppedWhileQueued), kindCancelled)
}

func TestBridgeErrorsPassThroughClassification(t *testing.T) {
	original := parameterError(2, expectDate, "2024-02-30")
	if classifyError(original) != original {
		t.Fatal("a classified error was rewritten")
	}
	assertKind(t, classifyError(errors.New("something else")), kindInternal)
}

func TestSessionStaysLostAfterAConnectionFailure(t *testing.T) {
	id := openTestSession(t, unreachableConfig(1))
	entry, failure := testBridge.sessions.lookup(id)
	if failure != nil {
		t.Fatal(failure)
	}
	assertKind(t, entry.failure(nil, fmt.Errorf("%w: %w", driver.ErrBadConn, io.EOF)), kindConnectionLost)
	if entry.currentState() != sessionLost || !entry.dialer.isSevered() {
		t.Fatalf("state=%v severed=%v; want a lost, severed session", entry.currentState(), entry.dialer.isSevered())
	}
	_, failure = testBridge.executeOnSession(id, 1, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindConnectionLost)
	_, failure = testBridge.explainOnSession(id, 2, []byte(`{"sql":"SELECT 1 FROM DUMMY"}`))
	assertKind(t, failure, kindConnectionLost)
	assertKind(t, testBridge.pingSession(id, 3), kindConnectionLost)
	_, failure = testBridge.connectSession(id, 4)
	assertKind(t, failure, kindConnectionLost)
}

func TestHandshakeFailuresMapToTLSSubkinds(t *testing.T) {
	hostnameMismatch := x509.HostnameError{Certificate: &x509.Certificate{}, Host: "db.example.com"}
	cases := []struct {
		err  error
		code int
	}{
		{x509.UnknownAuthorityError{}, tlsFailureUntrusted},
		{x509.CertificateInvalidError{Reason: x509.Expired}, tlsFailureUntrusted},
		{&tls.CertificateVerificationError{Err: x509.UnknownAuthorityError{}}, tlsFailureUntrusted},
		{&tls.CertificateVerificationError{Err: errors.New("x509: platform verifier said no")}, tlsFailureUntrusted},
		{hostnameMismatch, tlsFailureHostnameMismatch},
		{&tls.CertificateVerificationError{Err: hostnameMismatch}, tlsFailureHostnameMismatch},
		{tls.RecordHeaderError{Msg: "first record does not look like a TLS handshake"}, tlsFailurePlaintextServer},
		{io.EOF, tlsFailurePlaintextServer},
		{fmt.Errorf("read: %w", syscall.ECONNRESET), tlsFailurePlaintextServer},
		{errors.New("tls: handshake failure"), tlsFailureOther},
	}
	for _, testCase := range cases {
		failure := classifyConnectError(&opaqueConnectError{cause: &handshakeError{cause: testCase.err}})
		assertKind(t, failure, kindTLS)
		if failure.Code != testCase.code {
			t.Errorf("%v classified as code %d; want %d", testCase.err, failure.Code, testCase.code)
		}
	}
}

func TestConnectFailuresOutsideTheHandshake(t *testing.T) {
	dialFailure := &net.OpError{Op: "dial", Net: "tcp", Err: syscall.ECONNREFUSED}
	assertKind(t, classifyConnectError(&opaqueConnectError{cause: dialFailure}), kindConnect)
	assertKind(t, classifyConnectError(&net.DNSError{Err: "no such host", Name: "nowhere.invalid"}), kindConnect)
	authentication := classifyConnectError(&opaqueConnectError{cause: fakeServerError{code: 10, text: "authentication failed"}})
	assertKind(t, authentication, kindServer)
	if authentication.Code != 10 {
		t.Fatalf("authentication failure = %+v", authentication)
	}
	assertKind(t, classifyError(&opaqueConnectError{cause: dialFailure}), kindConnect)
	if errors.Is(&opaqueConnectError{cause: fmt.Errorf("%w: %w", driver.ErrBadConn, io.EOF)}, driver.ErrBadConn) {
		t.Fatal("a connect error exposes ErrBadConn, so database/sql would dial again")
	}
}

func TestConnectContextDecidesCancelledAndTimeout(t *testing.T) {
	expired, cancelExpired := context.WithTimeout(context.Background(), 0)
	defer cancelExpired()
	<-expired.Done()
	assertKind(t, connectFailure(expired, net.ErrClosed), kindTimeout)
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	assertKind(t, connectFailure(cancelled, net.ErrClosed), kindCancelled)
	assertKind(t, connectFailure(context.Background(), &net.OpError{Op: "dial", Err: syscall.ECONNREFUSED}), kindConnect)
}

func TestCleanupConnectionFailureTurnsASuccessIntoConnectionLost(t *testing.T) {
	var err error
	cleanupInto(&err, func() error { return fmt.Errorf("%w: %w", driver.ErrBadConn, io.EOF) })
	failure := resolveFailure(sessionConnected, stopNone, err)
	assertKind(t, failure, kindConnectionLost)
	if failure.Message != "EOF" {
		t.Fatalf("message = %q; want the cleanup's own failure", failure.Message)
	}
}

func TestCleanupFailureThatIsNotAConnectionFailureNeverOverridesTheStatement(t *testing.T) {
	err := error(fakeServerError{code: 259, text: "invalid table name"})
	cleanupInto(&err, func() error { return fakeServerError{code: 7, text: "drop statement refused"} })
	failure := resolveFailure(sessionConnected, stopNone, err)
	assertKind(t, failure, kindServer)
	if failure.Code != 259 {
		t.Fatalf("failure = %+v; want the statement's error", failure)
	}
	var succeeded error
	cleanupInto(&succeeded, func() error { return errors.New("drop statement refused") })
	if succeeded != nil {
		t.Fatalf("a cleanup error that is not a connection failure failed a statement that succeeded: %v", succeeded)
	}
}

func TestCleanupConnectionFailureOutranksTheStatementError(t *testing.T) {
	statementErrors := []error{
		fakeServerError{code: 259, text: "invalid table name"},
		cancelledByServer,
		errOperationStopped,
		parameterError(1, expectDate, "2024-02-30"),
	}
	for _, statementErr := range statementErrors {
		err := joinCleanupFailure(statementErr, net.ErrClosed)
		if !errors.Is(err, statementErr) {
			t.Fatalf("the joined failure dropped the statement error %v", statementErr)
		}
		for _, reason := range []stopReason{stopNone, stopCancelled, stopTimedOut} {
			failure := resolveFailure(sessionConnected, reason, err)
			assertKind(t, failure, kindConnectionLost)
			if failure.Message != net.ErrClosed.Error() {
				t.Fatalf("message = %q; want the cleanup failure alone", failure.Message)
			}
		}
	}
}

func TestAnUnfinishedTransactionDropsTheSession(t *testing.T) {
	statementErr := errors.New("unique constraint violated")
	rollbackErr := errors.New("SQL error 3: fatal error: transaction is not active")
	failure := unsettledTransaction(statementErr, rollbackErr)
	if !isConnectionFailure(failure) {
		t.Fatal("a failed rollback left the session reusable")
	}
	classified := resolveFailure(sessionConnected, stopNone, failure)
	assertKind(t, classified, kindConnectionLost)
	if !strings.Contains(classified.Message, "transaction is not active") || !strings.Contains(classified.Message, "unique constraint violated") {
		t.Fatalf("message %q lost a cause", classified.Message)
	}
	commitFailure := unsettledTransaction(nil, errors.New("commit refused"))
	assertKind(t, resolveFailure(sessionConnected, stopNone, commitFailure), kindConnectionLost)
	if isConnectionFailure(statementErr) {
		t.Fatal("a plain statement error was read as a lost session")
	}
}
