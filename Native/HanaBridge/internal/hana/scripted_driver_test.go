package hana

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"testing"
	"time"
)

var errScriptedCallUnsupported = errors.New("the scripted driver does not script this call")

type scriptedDriver struct{}

func (scriptedDriver) Open(string) (driver.Conn, error) {
	return nil, errScriptedCallUnsupported
}

type scriptedConnector struct {
	conn *scriptedConn
}

func (c scriptedConnector) Connect(context.Context) (driver.Conn, error) {
	return c.conn, nil
}

func (c scriptedConnector) Driver() driver.Driver {
	return scriptedDriver{}
}

type scriptedConn struct {
	exec         func(query string) (driver.Result, error)
	query        func(query string) (driver.Rows, error)
	queryContext func(context.Context, string) (driver.Rows, error)
	ping         func() error
}

func (c *scriptedConn) Prepare(string) (driver.Stmt, error) {
	return nil, errScriptedCallUnsupported
}

func (c *scriptedConn) Close() error {
	return nil
}

func (c *scriptedConn) Begin() (driver.Tx, error) {
	return nil, errScriptedCallUnsupported
}

func (c *scriptedConn) ExecContext(_ context.Context, query string, _ []driver.NamedValue) (driver.Result, error) {
	if c.exec == nil {
		return nil, errScriptedCallUnsupported
	}
	return c.exec(query)
}

func (c *scriptedConn) QueryContext(ctx context.Context, query string, _ []driver.NamedValue) (driver.Rows, error) {
	if c.queryContext != nil {
		return c.queryContext(ctx, query)
	}
	if c.query == nil {
		return nil, errScriptedCallUnsupported
	}
	return c.query(query)
}

func (c *scriptedConn) Ping(context.Context) error {
	if c.ping == nil {
		return nil
	}
	return c.ping()
}

type scriptedRows struct {
	columns  []string
	values   [][]driver.Value
	next     int
	closeErr error
	closes   int
}

func (r *scriptedRows) Columns() []string {
	return r.columns
}

func (r *scriptedRows) Close() error {
	r.closes++
	return r.closeErr
}

func (r *scriptedRows) Next(destination []driver.Value) error {
	if r.next >= len(r.values) {
		return io.EOF
	}
	copy(destination, r.values[r.next])
	r.next++
	return nil
}

func scriptedSession(t *testing.T, conn *scriptedConn) *session {
	t.Helper()
	entry := connectedTestSession(t, closedPort(t), 0)
	db := sql.OpenDB(scriptedConnector{conn: conn})
	t.Cleanup(func() { _ = db.Close() })
	pinned, err := db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	entry.mu.Lock()
	entry.conn = pinned
	entry.mu.Unlock()
	return entry
}

func TestIdentityQueryUsesTheConnectDeadline(t *testing.T) {
	conn := &scriptedConn{queryContext: func(ctx context.Context, _ string) (driver.Rows, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}}
	db := sql.OpenDB(scriptedConnector{conn: conn})
	t.Cleanup(func() { _ = db.Close() })
	entry := &session{db: db}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	_, _, err := entry.establish(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("establish returned %v; want the connect deadline", err)
	}
}
