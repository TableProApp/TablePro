package hana

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"syscall"

	hdb "github.com/SAP/go-hdb/driver"
)

const (
	kindServer         = "server"
	kindCancelled      = "cancelled"
	kindTimeout        = "timeout"
	kindConnectionLost = "connectionLost"
	kindClosed         = "closed"
	kindParameter      = "parameter"
	kindTLS            = "tls"
	kindConfiguration  = "configuration"
	kindConnect        = "connect"
	kindInternal       = "internal"
)

const (
	tlsFailureOther             = 0
	tlsFailureUntrusted         = 1
	tlsFailureHostnameMismatch  = 2
	tlsFailurePlaintextServer   = 3
	tlsFailureClientCertificate = 4
)

const hanaStatementCancelledCode = 139

type bridgeError struct {
	Kind      string `json:"kind"`
	Code      int    `json:"code"`
	Position  int    `json:"position"`
	Message   string `json:"message"`
	Parameter int    `json:"parameter"`
	Expected  string `json:"expected"`
}

func (e *bridgeError) Error() string {
	if e.Message == "" {
		return e.Kind
	}
	return e.Kind + ": " + e.Message
}

func (e *bridgeError) encoded() []byte {
	data, err := json.Marshal(e)
	if err != nil {
		return []byte(`{"kind":"internal","code":0,"position":0,"message":"","parameter":0,"expected":""}`)
	}
	return data
}

func internalError(message string) *bridgeError {
	return &bridgeError{Kind: kindInternal, Message: message}
}

func configurationError(message string) *bridgeError {
	return &bridgeError{Kind: kindConfiguration, Message: message}
}

func closedError() *bridgeError {
	return &bridgeError{Kind: kindClosed}
}

func connectionLostError(cause error) *bridgeError {
	return &bridgeError{Kind: kindConnectionLost, Message: plainErrorText(cause)}
}

func tlsError(code int, cause error) *bridgeError {
	return &bridgeError{Kind: kindTLS, Code: code, Message: plainErrorText(cause)}
}

func stoppedError(reason stopReason) *bridgeError {
	switch reason {
	case stopTimedOut:
		return &bridgeError{Kind: kindTimeout}
	case stopClosed:
		return closedError()
	default:
		return &bridgeError{Kind: kindCancelled}
	}
}

func serverError(failure hdb.DBError) *bridgeError {
	return &bridgeError{
		Kind:     kindServer,
		Code:     failure.Code(),
		Position: failure.Position(),
		Message:  decodeText([]byte(failure.Text())),
	}
}

func parameterError(position int, expected string, text string) *bridgeError {
	return &bridgeError{Kind: kindParameter, Parameter: position, Expected: expected, Message: text}
}

type opaqueConnectError struct {
	cause error
}

func (e *opaqueConnectError) Error() string {
	return e.cause.Error()
}

type handshakeError struct {
	cause error
}

func (e *handshakeError) Error() string {
	return e.cause.Error()
}

func (e *handshakeError) Unwrap() error {
	return e.cause
}

func plainErrorText(err error) string {
	if err == nil {
		return ""
	}
	return strings.ReplaceAll(err.Error(), driver.ErrBadConn.Error()+": ", "")
}

func serverErrorCode(err error) (int, bool) {
	var failure hdb.DBError
	if !errors.As(err, &failure) {
		return 0, false
	}
	return failure.Code(), true
}

type cleanupFailure struct {
	cleanup   error
	statement error
}

func (f *cleanupFailure) Error() string {
	return f.cleanup.Error()
}

func (f *cleanupFailure) Unwrap() []error {
	return []error{f.cleanup, f.statement}
}

func joinCleanupFailure(statementErr error, cleanupErr error) error {
	if !isConnectionFailure(cleanupErr) {
		return statementErr
	}
	if statementErr == nil {
		return cleanupErr
	}
	return &cleanupFailure{cleanup: cleanupErr, statement: statementErr}
}

func cleanupInto(err *error, cleanup func() error) {
	*err = joinCleanupFailure(*err, cleanup())
}

var errTransactionUnsettled = errors.New("the transaction could not be finished")

type transactionFailure struct {
	finalize  error
	statement error
}

func (e *transactionFailure) Error() string {
	if e.statement == nil {
		return e.finalize.Error()
	}
	return e.finalize.Error() + "; " + e.statement.Error()
}

func (e *transactionFailure) Unwrap() []error {
	return []error{errTransactionUnsettled, e.finalize}
}

func unsettledTransaction(statementErr error, finalizeErr error) error {
	return &transactionFailure{finalize: finalizeErr, statement: statementErr}
}

func isConnectionFailure(err error) bool {
	if errors.Is(err, driver.ErrBadConn) || errors.Is(err, sql.ErrConnDone) || errors.Is(err, errDialerSevered) || errors.Is(err, errPingUnanswered) {
		return true
	}
	if errors.Is(err, errTransactionUnsettled) {
		return true
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, net.ErrClosed) {
		return true
	}
	var networkFailure net.Error
	return errors.As(err, &networkFailure)
}

func classifyError(err error) *bridgeError {
	var opaque *opaqueConnectError
	if errors.As(err, &opaque) {
		return classifyConnectError(opaque.cause)
	}
	if isConnectionFailure(err) {
		return connectionLostError(err)
	}
	var classified *bridgeError
	if errors.As(err, &classified) {
		return classified
	}
	var failure hdb.DBError
	if errors.As(err, &failure) {
		return serverError(failure)
	}
	return internalError(plainErrorText(err))
}

func classifyConnectError(err error) *bridgeError {
	var opaque *opaqueConnectError
	if errors.As(err, &opaque) {
		err = opaque.cause
	}
	var handshake *handshakeError
	if errors.As(err, &handshake) {
		return classifyHandshakeError(handshake.cause)
	}
	var failure hdb.DBError
	if errors.As(err, &failure) {
		return serverError(failure)
	}
	return &bridgeError{Kind: kindConnect, Message: plainErrorText(err)}
}

func classifyHandshakeError(err error) *bridgeError {
	if code, ok := certificateFailureCode(err); ok {
		return tlsError(code, err)
	}
	var recordHeader tls.RecordHeaderError
	if errors.As(err, &recordHeader) {
		return tlsError(tlsFailurePlaintextServer, err)
	}
	if isPlaintextHangUp(err) {
		return tlsError(tlsFailurePlaintextServer, err)
	}
	return tlsError(tlsFailureOther, err)
}

func certificateFailureCode(err error) (int, bool) {
	var hostname x509.HostnameError
	if errors.As(err, &hostname) {
		return tlsFailureHostnameMismatch, true
	}
	var verification *tls.CertificateVerificationError
	if errors.As(err, &verification) {
		return tlsFailureUntrusted, true
	}
	var unknownAuthority x509.UnknownAuthorityError
	if errors.As(err, &unknownAuthority) {
		return tlsFailureUntrusted, true
	}
	var invalid x509.CertificateInvalidError
	if errors.As(err, &invalid) {
		return tlsFailureUntrusted, true
	}
	return 0, false
}

func isPlaintextHangUp(err error) bool {
	return errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, syscall.ECONNRESET)
}

func resolveFailure(state sessionState, reason stopReason, err error) *bridgeError {
	if state == sessionClosed || errors.Is(err, errSlotClosed) {
		return closedError()
	}
	if errors.Is(err, errOperationDroppedWhileQueued) {
		return stoppedError(stopCancelled)
	}
	classified := classifyError(err)
	if classified.Kind == kindConnectionLost {
		return classified
	}
	if state == sessionLost {
		return connectionLostError(err)
	}
	if reason == stopNone {
		return classified
	}
	if errors.Is(err, errOperationStopped) || isStatementCancelledByServer(err) {
		return stoppedError(reason)
	}
	return classified
}

func isStatementCancelledByServer(err error) bool {
	code, ok := serverErrorCode(err)
	return ok && code == hanaStatementCancelledCode
}

func connectFailure(connectContext context.Context, err error) *bridgeError {
	switch {
	case errors.Is(connectContext.Err(), context.DeadlineExceeded):
		return stoppedError(stopTimedOut)
	case errors.Is(connectContext.Err(), context.Canceled):
		return stoppedError(stopCancelled)
	}
	return classifyConnectError(err)
}
