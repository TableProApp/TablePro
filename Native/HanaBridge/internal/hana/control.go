package hana

import (
	"context"
	"database/sql"
	"errors"
	"strconv"
	"time"
)

const cancelDeadline = 10 * time.Second

var errUnknownServerConnection = errors.New("the server connection id is unknown")

func cancelSessionStatement(connectionID int64) string {
	return "ALTER SYSTEM CANCEL SESSION '" + strconv.FormatInt(connectionID, 10) + "'"
}

func (s *session) interruptStatement(reason stopReason) {
	if reason == stopClosed {
		return
	}
	defer func() {
		if recover() != nil {
			s.loseConnection()
		}
	}()
	if _, err := runUnderWatchdog(cancelDeadline, s.loseConnection, s.sendCancel); err != nil {
		s.loseConnection()
	}
}

func (s *session) sendCancel() error {
	connectionID := s.serverConnectionID()
	if connectionID <= 0 {
		return errUnknownServerConnection
	}
	statement := cancelSessionStatement(connectionID)
	s.controlMu.Lock()
	defer s.controlMu.Unlock()
	conn, reused, err := s.controlConnection()
	if err != nil {
		return err
	}
	_, err = conn.ExecContext(context.Background(), statement)
	if err == nil {
		return nil
	}
	s.discardControlConnection()
	if !reused || !isConnectionFailure(err) {
		return err
	}
	conn, _, err = s.controlConnection()
	if err != nil {
		return err
	}
	if _, err = conn.ExecContext(context.Background(), statement); err != nil {
		s.discardControlConnection()
	}
	return err
}

func (s *session) controlConnection() (*sql.Conn, bool, error) {
	if s.control != nil {
		return s.control, true, nil
	}
	dialContext, cancel := context.WithTimeout(context.Background(), cancelDeadline)
	defer cancel()
	conn, err := s.controlDB.Conn(dialContext)
	if err != nil {
		return nil, false, err
	}
	s.control = conn
	return conn, false, nil
}

func (s *session) discardControlConnection() {
	if s.control == nil {
		return
	}
	_ = s.control.Close()
	s.control = nil
}
