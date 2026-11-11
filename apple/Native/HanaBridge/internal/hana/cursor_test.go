package hana

import (
	"encoding/json"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

const selectAll = "SELECT ID, NAME FROM T"

type cursorReply struct {
	Columns           []string    `json:"columns"`
	ColumnTypeNames   []string    `json:"columnTypeNames"`
	RowsAffected      int64       `json:"rowsAffected"`
	HasResultSet      bool        `json:"hasResultSet"`
	Rows              [][]*string `json:"rows"`
	TruncatedLobCount int         `json:"truncatedLobCount"`
	Done              bool        `json:"done"`
	SessionLost       bool        `json:"sessionLost"`
	IsTruncated       bool        `json:"isTruncated"`
}

func decodeReply(t *testing.T, encoded []byte, failure *bridgeError) cursorReply {
	t.Helper()
	if failure != nil {
		t.Fatalf("the helper answered with a failure: %v", failure)
	}
	var reply cursorReply
	if err := json.Unmarshal(encoded, &reply); err != nil {
		t.Fatalf("the reply is not JSON: %v\n%s", err, encoded)
	}
	return reply
}

func requireRefused(t *testing.T, encoded []byte, failure *bridgeError, kind string) *bridgeError {
	t.Helper()
	if failure == nil {
		t.Fatalf("the helper answered %s, want a %s failure", encoded, kind)
	}
	if failure.Kind != kind {
		t.Fatalf("the failure is %v, want kind %s", failure, kind)
	}
	return failure
}

func cursorOver(sql string, batchRows int) cursorRequest {
	return cursorRequest{executeRequest: executeRequest{SQL: sql}, BatchRows: batchRows}
}

func mustOpen(t *testing.T, entry *session, operationID uint64, request cursorRequest) cursorReply {
	t.Helper()
	encoded, failure := entry.openCursor(operationID, request)
	return decodeReply(t, encoded, failure)
}

func mustFetch(t *testing.T, entry *session, operationID uint64) cursorReply {
	t.Helper()
	encoded, failure := entry.fetch(operationID)
	return decodeReply(t, encoded, failure)
}

func mustExecute(t *testing.T, entry *session, operationID uint64, request executeRequest) cursorReply {
	t.Helper()
	encoded, failure := entry.execute(operationID, request)
	return decodeReply(t, encoded, failure)
}

func requireFetchRefused(t *testing.T, entry *session, operationID uint64) *bridgeError {
	t.Helper()
	encoded, failure := entry.fetch(operationID)
	return requireRefused(t, encoded, failure, kindInternal)
}

func parkedOperation(entry *session) *operation {
	entry.mu.Lock()
	defer entry.mu.Unlock()
	return entry.parkedCursor.op
}

func firstColumn(rows [][]*string) []string {
	values := make([]string, 0, len(rows))
	for _, row := range rows {
		if row[0] == nil {
			values = append(values, "NULL")
			continue
		}
		values = append(values, *row[0])
	}
	return values
}

func numbered(count int) []string {
	values := make([]string, count)
	for index := range values {
		values[index] = strconv.Itoa(index)
	}
	return values
}

func drain(t *testing.T, entry *session, operationID uint64, opened cursorReply) (batchSizes []int, ids []string) {
	t.Helper()
	reply := opened
	batchSizes = append(batchSizes, len(reply.Rows))
	ids = append(ids, firstColumn(reply.Rows)...)
	for !reply.Done {
		reply = mustFetch(t, entry, operationID)
		batchSizes = append(batchSizes, len(reply.Rows))
		ids = append(ids, firstColumn(reply.Rows)...)
	}
	return batchSizes, ids
}

func TestCursorReadsEveryRowInBatchesAndMarksTheLastDone(t *testing.T) {
	server := newFakeServer(table(10))
	entry := connectedSession(t, server)

	opened := mustOpen(t, entry, 1, cursorOver(selectAll, 3))

	if !slices.Equal(opened.Columns, []string{"ID", "NAME"}) {
		t.Fatalf("columns are %v", opened.Columns)
	}
	if !slices.Equal(opened.ColumnTypeNames, []string{"INTEGER", "NVARCHAR"}) {
		t.Fatalf("column types are %v", opened.ColumnTypeNames)
	}
	if !opened.HasResultSet || opened.Done {
		t.Fatalf("the opened cursor reads hasResultSet %v, done %v", opened.HasResultSet, opened.Done)
	}
	sizes, ids := drain(t, entry, 1, opened)
	if !slices.Equal(sizes, []int{3, 3, 3, 1}) {
		t.Fatalf("batch sizes are %v, want [3 3 3 1]", sizes)
	}
	if !slices.Equal(ids, numbered(10)) {
		t.Fatalf("rows arrived as %v", ids)
	}
	if !server.lastRows().closed.Load() {
		t.Fatal("the rows stayed open after the last batch")
	}
	requireFetchRefused(t, entry, 1)
	requireSlotFree(t, entry, 2)
}

func TestCursorMarksAnExactMultipleDoneOnItsLastBatch(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(6)))

	opened := mustOpen(t, entry, 1, cursorOver(selectAll, 3))
	if opened.Done {
		t.Fatal("the first of two full batches reads done")
	}
	last := mustFetch(t, entry, 1)

	if len(last.Rows) != 3 || !last.Done {
		t.Fatalf("the last batch has %d rows and done %v, want 3 and true", len(last.Rows), last.Done)
	}
	requireSlotFree(t, entry, 2)
}

func TestCursorOverNoRowsSendsTheHeaderAndDone(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(0)))

	opened := mustOpen(t, entry, 1, cursorOver(selectAll, 3))

	if len(opened.Rows) != 0 || !opened.Done || !opened.HasResultSet {
		t.Fatalf("an empty result opened with %d rows, done %v, hasResultSet %v", len(opened.Rows), opened.Done, opened.HasResultSet)
	}
	if !slices.Equal(opened.Columns, []string{"ID", "NAME"}) {
		t.Fatalf("columns are %v", opened.Columns)
	}
	requireSlotFree(t, entry, 2)
}

func TestCursorEndsABatchAtItsByteBudget(t *testing.T) {
	wide := table(10)
	wide.name = strings.Repeat("x", 1<<20)
	entry := connectedSession(t, newFakeServer(wide))

	opened := mustOpen(t, entry, 1, cursorOver(selectAll, 1_000))
	sizes, ids := drain(t, entry, 1, opened)

	if !slices.Equal(sizes, []int{4, 4, 2}) {
		t.Fatalf("batch sizes are %v, want [4 4 2] for 1 MiB rows under a 4 MiB budget", sizes)
	}
	if !slices.Equal(ids, numbered(10)) {
		t.Fatalf("rows arrived as %v", ids)
	}
}

func TestStatementWithoutAResultSetOpensNoCursor(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(10)))

	opened := mustOpen(t, entry, 1, cursorOver("INSERT INTO T VALUES (1, 'a')", 3))

	if opened.HasResultSet || !opened.Done || opened.RowsAffected != 1 || len(opened.Rows) != 0 {
		t.Fatalf("an insert opened as %+v", opened)
	}
	requireFetchRefused(t, entry, 1)
	requireSlotFree(t, entry, 2)
}

func TestClosingACursorEarlyClosesItsRowsAndFreesTheSlot(t *testing.T) {
	server := newFakeServer(table(10))
	entry := connectedSession(t, server)
	mustOpen(t, entry, 1, cursorOver(selectAll, 3))
	rows := server.lastRows()

	encoded, failure := entry.closeCursor(1)
	closed := decodeReply(t, encoded, failure)

	if closed.SessionLost {
		t.Fatal("closing a cursor lost the session")
	}
	if !rows.closed.Load() {
		t.Fatal("closing the cursor left its rows open")
	}
	if served := rows.served.Load(); served != 4 {
		t.Fatalf("the server handed out %d rows, want the 3 sent and the 1 read ahead", served)
	}
	requireFetchRefused(t, entry, 1)
	requireSlotFree(t, entry, 2)
}

func TestStopBetweenFetchesFailsTheNextFetchWithoutCancellingOnTheServer(t *testing.T) {
	server := newFakeServer(table(10))
	entry := connectedSession(t, server)
	mustOpen(t, entry, 1, cursorOver(selectAll, 3))
	rows := server.lastRows()
	op := parkedOperation(entry)

	entry.cancel(1)
	op.inFlight.Wait()
	encoded, failure := entry.fetch(1)

	requireRefused(t, encoded, failure, kindCancelled)
	if !rows.closed.Load() {
		t.Fatal("a stopped cursor left its rows open")
	}
	for _, statement := range server.executed() {
		if strings.HasPrefix(statement, "ALTER SYSTEM CANCEL SESSION") {
			t.Fatalf("a stop between fetches sent %q, though no statement was running", statement)
		}
	}
	requireSlotFree(t, entry, 2)
}

func TestStopDuringAFetchEndsItAtTheNextRowWithoutCancellingOnTheServer(t *testing.T) {
	held := table(10)
	held.hold = holdRow(4)
	server := newFakeServer(held)
	entry := connectedSession(t, server)
	mustOpen(t, entry, 1, cursorOver(selectAll, 3))
	rows := server.lastRows()
	op := parkedOperation(entry)
	type outcome struct {
		encoded []byte
		failure *bridgeError
	}
	fetched := make(chan outcome, 1)
	go func() {
		encoded, failure := entry.fetch(1)
		fetched <- outcome{encoded: encoded, failure: failure}
	}()
	select {
	case <-held.hold.reached:
	case <-time.After(5 * time.Second):
		t.Fatal("the fetch never reached the held row")
	}

	entry.cancel(1)
	op.inFlight.Wait()
	close(held.hold.released)

	var result outcome
	select {
	case result = <-fetched:
	case <-time.After(5 * time.Second):
		t.Fatal("the stopped fetch never answered")
	}
	requireRefused(t, result.encoded, result.failure, kindCancelled)
	if served := rows.served.Load(); served != 5 {
		t.Fatalf("the server handed out %d rows, want the fetch to stop at the row it was reading", served)
	}
	if !rows.closed.Load() {
		t.Fatal("a fetch stopped in flight left the rows open")
	}
	for _, statement := range server.executed() {
		if strings.HasPrefix(statement, "ALTER SYSTEM CANCEL SESSION") {
			t.Fatalf("a stop after the result existed sent %q", statement)
		}
	}
	requireSlotFree(t, entry, 2)
}

func TestFetchThatFailsClosesTheCursor(t *testing.T) {
	failing := table(10)
	failing.failAt = 5
	server := newFakeServer(failing)
	entry := connectedSession(t, server)
	mustOpen(t, entry, 1, cursorOver(selectAll, 3))
	rows := server.lastRows()

	encoded, failure := entry.fetch(1)

	refused := requireRefused(t, encoded, failure, kindInternal)
	if !strings.Contains(refused.Message, errFakeRead.Error()) {
		t.Fatalf("the failure reads %q, want the server's read error", refused.Message)
	}
	if !rows.closed.Load() {
		t.Fatal("a failed fetch left the rows open")
	}
	requireFetchRefused(t, entry, 1)
	// The next statement reads a table that no longer fails, so only a held slot can fail it.
	server.mu.Lock()
	server.table.failAt = -1
	server.mu.Unlock()
	requireSlotFree(t, entry, 2)
}

func TestFetchWithNoOpenCursorIsRefused(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(10)))

	refused := requireFetchRefused(t, entry, 1)
	if refused.Message != noCursorMessage {
		t.Fatalf("the refusal reads %q", refused.Message)
	}
	encoded, failure := entry.closeCursor(1)
	requireRefused(t, encoded, failure, kindInternal)
	requireSlotFree(t, entry, 2)
}

func TestFetchForAnotherOperationLeavesTheCursorOpen(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(10)))
	mustOpen(t, entry, 5, cursorOver(selectAll, 3))

	requireFetchRefused(t, entry, 6)

	next := mustFetch(t, entry, 5)
	if !slices.Equal(firstColumn(next.Rows), []string{"3", "4", "5"}) {
		t.Fatalf("the cursor resumed at %v", firstColumn(next.Rows))
	}
}

func TestCursorRefusesParameters(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(10)))
	request := cursorOver(selectAll+" WHERE ID = ?", 3)
	request.Parameters = &[]cell{textCell("1")}

	encoded, failure := entry.openCursor(1, request)

	requireRefused(t, encoded, failure, kindInternal)
	requireSlotFree(t, entry, 2)
}

func TestQueryTimeoutStopsCoveringTheCursorOnceItIsOpen(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(10)))
	request := cursorOver(selectAll, 3)
	request.TimeoutSeconds = 0.2

	mustOpen(t, entry, 1, request)

	op := parkedOperation(entry)
	op.mu.Lock()
	armed := op.deadline != nil
	op.mu.Unlock()
	if armed {
		t.Fatal("the query timeout is still armed after the cursor opened")
	}
	// Twice the timeout: a deadline left armed would have stopped the cursor by now.
	time.Sleep(400 * time.Millisecond)
	if op.stopped() {
		t.Fatal("the query timeout stopped an open cursor")
	}
	if next := mustFetch(t, entry, 1); len(next.Rows) != 3 {
		t.Fatalf("a fetch past the timeout read %d rows", len(next.Rows))
	}
}

func TestClosingTheSessionClosesAParkedCursor(t *testing.T) {
	server := newFakeServer(table(10))
	entry := connectedSession(t, server)
	mustOpen(t, entry, 1, cursorOver(selectAll, 3))
	rows := server.lastRows()

	entry.close()

	deadline := time.Now().Add(5 * time.Second)
	for !rows.closed.Load() {
		if time.Now().After(deadline) {
			t.Fatal("closing the session left the parked cursor's rows open")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestCollectedExecuteStillCutsAtTheRowCap(t *testing.T) {
	entry := connectedSession(t, newFakeServer(table(10)))

	cut := mustExecute(t, entry, 1, executeRequest{SQL: selectAll, RowCap: 4})
	whole := mustExecute(t, entry, 2, executeRequest{SQL: selectAll, RowCap: 10})
	uncapped := mustExecute(t, entry, 3, executeRequest{SQL: selectAll})

	if !slices.Equal(firstColumn(cut.Rows), numbered(4)) || !cut.IsTruncated {
		t.Fatalf("a cap of 4 read %v, truncated %v", firstColumn(cut.Rows), cut.IsTruncated)
	}
	if len(whole.Rows) != 10 || whole.IsTruncated {
		t.Fatalf("a cap equal to the row count read %d rows, truncated %v", len(whole.Rows), whole.IsTruncated)
	}
	if len(uncapped.Rows) != 10 || uncapped.IsTruncated {
		t.Fatalf("no cap read %d rows, truncated %v", len(uncapped.Rows), uncapped.IsTruncated)
	}
}
