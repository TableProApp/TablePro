package hana

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"reflect"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var errFakeRead = errors.New("the fake server failed to read a row")

type fakeTable struct {
	rowCount int
	// The row whose read fails, or -1.
	failAt int
	name   string
	hold   *rowHold
}

// Holds the read of one row until the test releases it, like a fetch waiting on the server.
type rowHold struct {
	at       int
	reached  chan struct{}
	released chan struct{}
}

func holdRow(at int) *rowHold {
	return &rowHold{at: at, reached: make(chan struct{}, 1), released: make(chan struct{})}
}

func table(rowCount int) fakeTable {
	return fakeTable{rowCount: rowCount, failAt: -1}
}

func (t fakeTable) nameOf(index int) string {
	if t.name != "" {
		return t.name
	}
	return "row " + strconv.Itoa(index)
}

type fakeServer struct {
	table fakeTable

	mu     sync.Mutex
	opened []*fakeRows
	execs  []string
}

func newFakeServer(table fakeTable) *fakeServer {
	return &fakeServer{table: table}
}

func (f *fakeServer) Connect(context.Context) (driver.Conn, error) {
	return &fakeConn{server: f}, nil
}

func (f *fakeServer) Driver() driver.Driver {
	return fakeDriver{}
}

func (f *fakeServer) open() *fakeRows {
	f.mu.Lock()
	defer f.mu.Unlock()
	rows := &fakeRows{table: f.table}
	f.opened = append(f.opened, rows)
	return rows
}

func (f *fakeServer) lastRows() *fakeRows {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.opened) == 0 {
		return nil
	}
	return f.opened[len(f.opened)-1]
}

func (f *fakeServer) recordExec(statement string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.execs = append(f.execs, statement)
}

func (f *fakeServer) executed() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.execs...)
}

type fakeDriver struct{}

func (fakeDriver) Open(string) (driver.Conn, error) {
	return nil, errors.New("the fake server opens connections through its connector")
}

type fakeConn struct {
	server *fakeServer
}

func (c *fakeConn) Prepare(string) (driver.Stmt, error) {
	return nil, errors.New("the fake server prepares no statements")
}

func (c *fakeConn) Close() error {
	return nil
}

func (c *fakeConn) Begin() (driver.Tx, error) {
	return nil, errors.New("the fake server has no transactions")
}

func (c *fakeConn) QueryContext(context.Context, string, []driver.NamedValue) (driver.Rows, error) {
	return c.server.open(), nil
}

func (c *fakeConn) ExecContext(_ context.Context, statement string, _ []driver.NamedValue) (driver.Result, error) {
	c.server.recordExec(statement)
	return driver.RowsAffected(1), nil
}

type fakeRows struct {
	table  fakeTable
	served atomic.Int64
	closed atomic.Bool
}

func (r *fakeRows) Columns() []string {
	return []string{"ID", "NAME"}
}

func (r *fakeRows) Close() error {
	r.closed.Store(true)
	return nil
}

func (r *fakeRows) Next(dest []driver.Value) error {
	index := int(r.served.Load())
	if hold := r.table.hold; hold != nil && index == hold.at {
		hold.reached <- struct{}{}
		<-hold.released
	}
	if index == r.table.failAt {
		return errFakeRead
	}
	if index >= r.table.rowCount {
		return io.EOF
	}
	dest[0] = int64(index)
	dest[1] = r.table.nameOf(index)
	r.served.Add(1)
	return nil
}

func (r *fakeRows) ColumnTypeDatabaseTypeName(index int) string {
	if index == 0 {
		return "INTEGER"
	}
	return "NVARCHAR"
}

func (r *fakeRows) ColumnTypeScanType(index int) reflect.Type {
	if index == 0 {
		return reflect.TypeFor[int64]()
	}
	return reflect.TypeFor[string]()
}

func connectedSession(t *testing.T, server *fakeServer) *session {
	t.Helper()
	db := sql.OpenDB(server)
	conn, err := db.Conn(context.Background())
	if err != nil {
		t.Fatalf("the fake server refused a connection: %v", err)
	}
	entry := &session{
		dialer:       newTrackingDialer(nil, nil),
		db:           db,
		controlDB:    sql.OpenDB(server),
		state:        sessionConnected,
		conn:         conn,
		connectionID: 1,
	}
	entry.slot = newOperationSlot(ForcedSeverGrace, entry.loseConnection)
	t.Cleanup(entry.close)
	return entry
}

// A slot the cursor still held would block this statement forever.
func requireSlotFree(t *testing.T, entry *session, operationID uint64) {
	t.Helper()
	finished := make(chan *bridgeError, 1)
	go func() {
		_, failure := entry.execute(operationID, executeRequest{SQL: "SELECT ID, NAME FROM T"})
		finished <- failure
	}()
	select {
	case failure := <-finished:
		if failure != nil {
			t.Fatalf("a statement after the cursor failed: %v", failure)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the cursor still holds the operation slot")
	}
}
