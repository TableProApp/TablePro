package hana

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"time"

	hdb "github.com/SAP/go-hdb/driver"
	"github.com/SAP/go-hdb/driver/dial"
	"github.com/SAP/go-hdb/driver/unicode/cesu8"
	"golang.org/x/text/transform"
)

var errPingUnanswered = errors.New("the server did not answer the ping in time")

const ForcedSeverGrace = 30 * time.Second

const (
	applicationName = "TablePro"
	pingDeadline    = 20 * time.Second
	identityQuery   = "SELECT CURRENT_SCHEMA, CURRENT_CONNECTION FROM DUMMY"
)

type sessionState uint8

const (
	sessionOpened sessionState = iota
	sessionConnecting
	sessionConnected
	sessionLost
	sessionClosed
)

type singleAttemptConnector struct {
	connector *hdb.Connector
}

func (c singleAttemptConnector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.connector.Connect(ctx)
	if err != nil {
		return nil, &opaqueConnectError{cause: err}
	}
	return conn, nil
}

func (c singleAttemptConnector) Driver() driver.Driver {
	return c.connector.Driver()
}

type session struct {
	connectTimeout time.Duration
	connector      *hdb.Connector
	dialer         *trackingDialer
	db             *sql.DB
	controlDB      *sql.DB
	slot           *operationSlot

	mu           sync.Mutex
	state        sessionState
	conn         *sql.Conn
	connectionID int64

	controlMu sync.Mutex
	control   *sql.Conn
}

func newSession(config connectionConfig) (*session, *bridgeError) {
	tlsConfig, failure := buildTLSConfig(config, config.hostName())
	if failure != nil {
		return nil, failure
	}
	dialer := newTrackingDialer(dial.DefaultDialer, tlsConfig)
	connector := newConnector(config, dialer)
	source := singleAttemptConnector{connector: connector}
	db := sql.OpenDB(source)
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	controlDB := sql.OpenDB(source)
	controlDB.SetMaxOpenConns(1)
	controlDB.SetMaxIdleConns(1)
	entry := &session{
		connectTimeout: config.connectTimeout(),
		connector:      connector,
		dialer:         dialer,
		db:             db,
		controlDB:      controlDB,
	}
	entry.slot = newOperationSlot(ForcedSeverGrace, entry.loseConnection)
	return entry, nil
}

func newConnector(config connectionConfig, dialer dial.Dialer) *hdb.Connector {
	connector := hdb.NewBasicAuthConnector(config.address(), config.Username, config.Password)
	connector.SetTimeout(0)
	connector.SetApplicationName(applicationName)
	connector.SetLogger(slog.New(slog.DiscardHandler))
	connector.SetCESU8Decoder(lenientCESU8Decoder)
	connector.SetDialer(dialer)
	connector.SetDefaultSchema(config.Schema)
	return connector
}

func lenientCESU8Decoder() transform.Transformer {
	return cesu8.NewDecoder(cesu8.ReplaceErrorHandler)
}

func (s *session) currentState() sessionState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state
}

func (s *session) serverConnectionID() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.connectionID
}

func (s *session) loseConnection() {
	s.mu.Lock()
	if s.state != sessionClosed {
		s.state = sessionLost
	}
	s.mu.Unlock()
	s.dialer.sever()
}

func (s *session) failure(op *operation, err error) *bridgeError {
	classified := resolveFailure(s.currentState(), op.currentStopReason(), err)
	if classified.Kind == kindConnectionLost {
		s.loseConnection()
	}
	return classified
}

func (s *session) connect(operationID uint64) ([]byte, *bridgeError) {
	stoppable, stop := context.WithCancel(context.Background())
	defer stop()
	op, err := s.slot.begin(operationID, func(stopReason) { stop() })
	if err != nil {
		s.abandonConnect()
		return nil, s.failure(nil, err)
	}
	defer s.slot.finish(op)
	if failure := s.enterConnecting(); failure != nil {
		return nil, failure
	}
	connectContext, expire := context.WithTimeout(stoppable, s.connectTimeout)
	defer expire()
	stopSevering := context.AfterFunc(connectContext, s.dialer.sever)
	conn, identity, err := s.establish(connectContext)
	if !stopSevering() && err == nil {
		_ = conn.Close()
		err = connectContext.Err()
	}
	if err != nil {
		s.loseConnection()
		if s.currentState() == sessionClosed {
			return nil, closedError()
		}
		return nil, connectFailure(connectContext, err)
	}
	if failure := s.adopt(conn, identity.ConnectionID); failure != nil {
		return nil, failure
	}
	encoded, err := json.Marshal(identity)
	if err != nil {
		return nil, internalError(err.Error())
	}
	return encoded, nil
}

func (s *session) enterConnecting() *bridgeError {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch s.state {
	case sessionOpened:
		s.state = sessionConnecting
		return nil
	case sessionClosed:
		return closedError()
	case sessionLost:
		return connectionLostError(nil)
	default:
		return internalError("the session has already connected")
	}
}

func (s *session) abandonConnect() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state == sessionOpened {
		s.state = sessionLost
	}
}

func (s *session) establish(connectContext context.Context) (*sql.Conn, connectResult, error) {
	conn, err := s.db.Conn(connectContext)
	if err != nil {
		return nil, connectResult{}, err
	}
	identity, err := readIdentity(connectContext, conn)
	if err != nil {
		_ = conn.Close()
		return nil, connectResult{}, err
	}
	identity.ServerVersion = serverVersion(conn)
	return conn, identity, nil
}

func readIdentity(connectContext context.Context, conn *sql.Conn) (identity connectResult, err error) {
	rows, err := conn.QueryContext(connectContext, identityQuery)
	if err != nil {
		return connectResult{}, err
	}
	defer cleanupInto(&err, rows.Close)
	var schema, connectionID any
	if rows.Next() {
		if err := rows.Scan(&schema, &connectionID); err != nil {
			return connectResult{}, err
		}
	}
	if err := rows.Err(); err != nil {
		return connectResult{}, err
	}
	if text, ok := schema.([]byte); ok {
		identity.CurrentSchema = decodeText(text)
	}
	if number, ok := connectionID.(int64); ok {
		identity.ConnectionID = number
	}
	return identity, nil
}

func serverVersion(conn *sql.Conn) string {
	version := ""
	_ = conn.Raw(func(driverConn any) error {
		hanaConn, ok := driverConn.(hdb.Conn)
		if !ok || hanaConn.HDBVersion() == nil {
			return nil
		}
		version = hanaConn.HDBVersion().String()
		return nil
	})
	return version
}

func (s *session) adopt(conn *sql.Conn, connectionID int64) *bridgeError {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state != sessionConnecting {
		_ = conn.Close()
		if s.state == sessionClosed {
			return closedError()
		}
		return connectionLostError(nil)
	}
	s.state = sessionConnected
	s.conn = conn
	s.connectionID = connectionID
	return nil
}

func (s *session) beginStatement(operationID uint64) (*operation, *sql.Conn, *bridgeError) {
	op, err := s.slot.begin(operationID, s.interruptStatement)
	if err != nil {
		return nil, nil, s.failure(nil, err)
	}
	conn, failure := s.connectedConn()
	if failure != nil {
		s.slot.finish(op)
		return nil, nil, failure
	}
	return op, conn, nil
}

func (s *session) connectedConn() (*sql.Conn, *bridgeError) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch s.state {
	case sessionConnected:
		return s.conn, nil
	case sessionClosed:
		return nil, closedError()
	default:
		return nil, connectionLostError(nil)
	}
}

func (s *session) execute(operationID uint64, request executeRequest) ([]byte, *bridgeError) {
	op, conn, failure := s.beginStatement(operationID)
	if failure != nil {
		return nil, failure
	}
	defer s.slot.finish(op)
	op.stopAfter(secondsDuration(request.TimeoutSeconds))
	started := time.Now()
	envelope, err := runStatement(conn, op, request)
	elapsed := time.Since(started)
	op.settle()
	if err != nil {
		return nil, s.failure(op, err)
	}
	envelope.executionTime = elapsed.Seconds()
	envelope.sessionLost = s.currentState() == sessionLost
	return envelope.appendJSON(nil), nil
}

func (s *session) explain(operationID uint64, request explainRequest) ([]byte, *bridgeError) {
	op, conn, failure := s.beginStatement(operationID)
	if failure != nil {
		return nil, failure
	}
	defer s.slot.finish(op)
	op.stopAfter(secondsDuration(request.TimeoutSeconds))
	started := time.Now()
	statementName := newPlanStatementName()
	nodes, err := readPlan(conn, op, statementName, request.SQL)
	op.settle()
	s.discardPlan(conn, statementName)
	if err != nil {
		return nil, s.failure(op, err)
	}
	envelope := planEnvelope(renderPlan(nodes))
	envelope.executionTime = time.Since(started).Seconds()
	envelope.sessionLost = s.currentState() == sessionLost
	return envelope.appendJSON(nil), nil
}

func (s *session) discardPlan(conn *sql.Conn, statementName string) {
	if state := s.currentState(); state == sessionLost || state == sessionClosed {
		return
	}
	_, err := runUnderWatchdog(cancelDeadline, s.loseConnection, func() error {
		_, err := conn.ExecContext(context.Background(), planCleanupStatement(statementName))
		return err
	})
	if isConnectionFailure(err) {
		s.loseConnection()
	}
}

func (s *session) ping(operationID uint64) *bridgeError {
	op, conn, failure := s.beginStatement(operationID)
	if failure != nil {
		return failure
	}
	defer s.slot.finish(op)
	expired, err := runUnderWatchdog(pingDeadline, s.loseConnection, func() error {
		return conn.PingContext(context.Background())
	})
	if expired {
		err = errPingUnanswered
	}
	op.settle()
	if err != nil {
		return s.failure(op, err)
	}
	if s.currentState() == sessionLost {
		return connectionLostError(nil)
	}
	return nil
}

func (s *session) cancel(operationID uint64) {
	s.slot.cancel(operationID)
}

func (s *session) close() {
	s.mu.Lock()
	if s.state == sessionClosed {
		s.mu.Unlock()
		return
	}
	s.state = sessionClosed
	conn := s.conn
	s.conn = nil
	s.mu.Unlock()
	s.slot.close()
	s.dialer.sever()
	go s.release(conn)
}

func (s *session) release(conn *sql.Conn) {
	defer func() {
		_ = recover()
	}()
	if conn != nil {
		_ = conn.Close()
	}
	s.controlMu.Lock()
	s.discardControlConnection()
	s.controlMu.Unlock()
	_ = s.db.Close()
	_ = s.controlDB.Close()
}
