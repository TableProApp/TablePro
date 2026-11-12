package hana

import (
	"context"
	"database/sql"
	"sync/atomic"
)

const (
	defaultCursorBatchRows  = 1_000
	maxCursorBatchRows      = 100_000
	cursorBatchBytes        = 4 << 20
	noCursorMessage         = "no cursor is open for this operation"
	cursorParametersMessage = "a cursor takes no parameters"
)

type cursorRequest struct {
	executeRequest
	BatchRows int `json:"batchRows"`
}

func (r cursorRequest) batchRows() int {
	if r.BatchRows <= 0 {
		return defaultCursorBatchRows
	}
	return min(r.BatchRows, maxCursorBatchRows)
}

type cursor struct {
	op       *operation
	rows     *sql.Rows
	reader   *resultReader
	maxRows  int
	maxBytes int
}

func (c *cursor) nextBatch() (*rowBatch, error) {
	batch := &rowBatch{maxRows: c.maxRows, maxBytes: c.maxBytes}
	ended, err := c.reader.read(batch)
	batch.done = ended
	return batch, err
}

type openedStatement struct {
	header  *resultEnvelope
	rows    *sql.Rows
	columns []columnInfo
}

func (s *session) openCursor(operationID uint64, request cursorRequest) ([]byte, *bridgeError) {
	if request.hasParameters() {
		return nil, internalError(cursorParametersMessage)
	}
	// Once the result exists a stop sends no CANCEL SESSION: it would mostly reach an idle session, and a refused
	// cancel severs the session. The row loop polls the stop flag, and the forced sever covers an unanswered fetch.
	var resultReady atomic.Bool
	op, conn, failure := s.beginOperation(operationID, func(reason stopReason) {
		if !resultReady.Load() {
			s.interruptStatement(reason)
		}
	})
	if failure != nil {
		return nil, failure
	}
	op.stopAfter(secondsDuration(request.TimeoutSeconds))
	opened, err := openStatement(conn, op, request.SQL)
	if err != nil {
		return nil, s.endOperation(op, err)
	}
	if opened.rows == nil {
		s.slot.finish(op)
		opened.header.sessionLost = s.currentState() == sessionLost
		return appendCursorOpenedJSON(nil, opened.header, &rowBatch{done: true}), nil
	}
	resultReady.Store(true)
	// The query timeout covers producing the result. Moving its rows can take far longer.
	op.disarmDeadline()
	current := &cursor{
		op:       op,
		rows:     opened.rows,
		reader:   &resultReader{rows: opened.rows, columns: opened.columns, op: op},
		maxRows:  request.batchRows(),
		maxBytes: cursorBatchBytes,
	}
	batch, failure := s.advance(current)
	if failure != nil {
		return nil, failure
	}
	opened.header.sessionLost = s.currentState() == sessionLost
	return appendCursorOpenedJSON(nil, opened.header, batch), nil
}

func (s *session) fetch(operationID uint64) ([]byte, *bridgeError) {
	current, failure := s.takeCursor(operationID)
	if failure != nil {
		return nil, failure
	}
	batch, failure := s.advance(current)
	if failure != nil {
		return nil, failure
	}
	return appendCursorBatchJSON(nil, batch, s.currentState() == sessionLost), nil
}

func (s *session) closeCursor(operationID uint64) ([]byte, *bridgeError) {
	current, failure := s.takeCursor(operationID)
	if failure != nil {
		return nil, failure
	}
	_, err := runUnderWatchdog(cancelDeadline, s.loseConnection, current.rows.Close)
	if isConnectionFailure(err) {
		s.loseConnection()
	}
	s.slot.finish(current.op)
	return appendCursorClosedJSON(nil, s.currentState() == sessionLost), nil
}

func (s *session) advance(current *cursor) (*rowBatch, *bridgeError) {
	batch, err := current.nextBatch()
	if err == nil && !batch.done {
		if s.park(current) {
			return batch, nil
		}
		err = errSlotClosed
	}
	err = joinCleanupFailure(err, current.rows.Close())
	if failure := s.endOperation(current.op, err); failure != nil {
		return nil, failure
	}
	return batch, nil
}

func (s *session) endOperation(op *operation, err error) *bridgeError {
	op.settle()
	var failure *bridgeError
	if err != nil {
		failure = s.failure(op, err)
	}
	s.slot.finish(op)
	return failure
}

func (s *session) takeCursor(operationID uint64) (*cursor, *bridgeError) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state == sessionClosed {
		return nil, closedError()
	}
	current := s.parkedCursor
	if current == nil || current.op.id != operationID {
		return nil, internalError(noCursorMessage)
	}
	s.parkedCursor = nil
	return current, nil
}

func (s *session) park(current *cursor) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.state == sessionClosed {
		return false
	}
	s.parkedCursor = current
	return true
}

func openStatement(conn *sql.Conn, op *operation, statement string) (openedStatement, error) {
	if op.stopped() {
		return openedStatement{}, errOperationStopped
	}
	if routesToExec(statement) {
		envelope, err := runCountingStatement(conn, statement)
		return openedStatement{header: envelope}, err
	}
	rows, err := conn.QueryContext(context.Background(), statement)
	if err != nil {
		return openedStatement{}, err
	}
	found, err := moveToFirstResultSet(rows)
	var columns []columnInfo
	if err == nil && found {
		columns, err = describeColumns(rows)
	}
	if err != nil || !found {
		if err = joinCleanupFailure(err, rows.Close()); err != nil {
			return openedStatement{}, err
		}
		return openedStatement{header: affectedRowsEnvelope(0)}, nil
	}
	return openedStatement{header: tabularEnvelope(columns), rows: rows, columns: columns}, nil
}
