package hana

import (
	"database/sql/driver"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"strings"
	"testing"
)

type decodedResult struct {
	Rows         [][]string `json:"rows"`
	RowsAffected int64      `json:"rowsAffected"`
	IsTruncated  bool       `json:"isTruncated"`
	SessionLost  *bool      `json:"sessionLost"`
}

func decodeResult(t *testing.T, encoded []byte) decodedResult {
	t.Helper()
	var result decodedResult
	if err := json.Unmarshal(encoded, &result); err != nil {
		t.Fatalf("result %s: %v", encoded, err)
	}
	if result.SessionLost == nil {
		t.Fatalf("result %s has no sessionLost", encoded)
	}
	return result
}

func planRows(values ...[]driver.Value) *scriptedRows {
	return &scriptedRows{
		columns: []string{"OPERATOR_ID", "PARENT_OPERATOR_ID", "POSITION", "OPERATOR_NAME", "OPERATOR_DETAILS",
			"SCHEMA_NAME", "TABLE_NAME", "OUTPUT_SIZE", "SUBTREE_COST"},
		values: values,
	}
}

func TestHealthyStatementReportsTheSessionKept(t *testing.T) {
	entry := scriptedSession(t, &scriptedConn{exec: func(string) (driver.Result, error) {
		return driver.RowsAffected(2), nil
	}})
	encoded, failure := entry.execute(1, executeRequest{SQL: "UPDATE T SET A = 1"})
	if failure != nil {
		t.Fatal(failure)
	}
	result := decodeResult(t, encoded)
	if *result.SessionLost || result.RowsAffected != 2 {
		t.Fatalf("result = %+v; want two affected rows on a kept session", result)
	}
}

func TestStatementThatSucceedsAfterItsCancelFailedReportsTheLostSession(t *testing.T) {
	var entry *session
	entry = scriptedSession(t, &scriptedConn{exec: func(string) (driver.Result, error) {
		entry.cancel(1)
		waitFor(t, func() bool { return entry.currentState() == sessionLost })
		return driver.RowsAffected(1), nil
	}})
	encoded, failure := entry.execute(1, executeRequest{SQL: "INSERT INTO T VALUES (1)"})
	if failure != nil {
		t.Fatalf("a statement that committed answered %v; want its result", failure)
	}
	result := decodeResult(t, encoded)
	if !*result.SessionLost || result.RowsAffected != 1 {
		t.Fatalf("result = %+v; want the committed row and the lost session", result)
	}
}

func TestExplainReportsTheSessionLostWhileDiscardingThePlan(t *testing.T) {
	entry := scriptedSession(t, &scriptedConn{
		exec: func(query string) (driver.Result, error) {
			if strings.HasPrefix(query, "DELETE FROM SYS.EXPLAIN_PLAN_TABLE") {
				return nil, io.ErrUnexpectedEOF
			}
			return driver.RowsAffected(0), nil
		},
		query: func(string) (driver.Rows, error) {
			return planRows([]driver.Value{int64(1), nil, int64(1), "COLUMN SEARCH", "T.ID", nil, nil, float64(10), float64(0.5)}), nil
		},
	})
	encoded, failure := entry.explain(1, explainRequest{SQL: "SELECT ID FROM T"})
	if failure != nil {
		t.Fatal(failure)
	}
	result := decodeResult(t, encoded)
	want := [][]string{{"COLUMN SEARCH T.ID rows 10 cost 0.5"}}
	if !*result.SessionLost || !reflect.DeepEqual(result.Rows, want) {
		t.Fatalf("result = %+v; want the plan and the lost session", result)
	}
	if entry.currentState() != sessionLost {
		t.Fatalf("state = %v; want lost", entry.currentState())
	}
}

func TestExplainOnAKeptSessionDiscardsThePlan(t *testing.T) {
	var discarded []string
	entry := scriptedSession(t, &scriptedConn{
		exec: func(query string) (driver.Result, error) {
			if strings.HasPrefix(query, "DELETE FROM SYS.EXPLAIN_PLAN_TABLE") {
				discarded = append(discarded, query)
			}
			return driver.RowsAffected(0), nil
		},
		query: func(string) (driver.Rows, error) {
			return planRows(), nil
		},
	})
	encoded, failure := entry.explain(1, explainRequest{SQL: "SELECT ID FROM T"})
	if failure != nil {
		t.Fatal(failure)
	}
	if result := decodeResult(t, encoded); *result.SessionLost {
		t.Fatalf("result = %+v; want a kept session", result)
	}
	if len(discarded) != 1 {
		t.Fatalf("plan cleanup ran %d times; want once", len(discarded))
	}
}

func TestTruncatedResultWhoseCloseLosesTheConnectionIsConnectionLost(t *testing.T) {
	rows := &scriptedRows{columns: []string{"ID"}, values: [][]driver.Value{{int64(1)}, {int64(2)}}, closeErr: net.ErrClosed}
	entry := scriptedSession(t, &scriptedConn{query: func(string) (driver.Rows, error) { return rows, nil }})
	_, failure := entry.execute(1, executeRequest{SQL: "SELECT ID FROM T", RowCap: 1})
	assertKind(t, failure, kindConnectionLost)
	if entry.currentState() != sessionLost || rows.closes != 1 {
		t.Fatalf("state=%v closes=%d; want a lost session after one close", entry.currentState(), rows.closes)
	}
}

func TestFullyReadResultWhoseCloseLosesTheConnectionIsConnectionLost(t *testing.T) {
	socketFailure := fmt.Errorf("%w: %w", driver.ErrBadConn, io.EOF)
	rows := &scriptedRows{columns: []string{"ID"}, values: [][]driver.Value{{int64(1)}}, closeErr: socketFailure}
	entry := scriptedSession(t, &scriptedConn{query: func(string) (driver.Rows, error) { return rows, nil }})
	_, failure := entry.execute(1, executeRequest{SQL: "SELECT ID FROM T"})
	assertKind(t, failure, kindConnectionLost)
	if entry.currentState() != sessionLost {
		t.Fatalf("state = %v; want lost", entry.currentState())
	}
}

func TestResultWhoseCloseFailsWithoutLosingTheConnectionKeepsTheResult(t *testing.T) {
	rows := &scriptedRows{columns: []string{"ID"}, values: [][]driver.Value{{int64(1)}, {int64(2)}}, closeErr: errors.New("close refused")}
	entry := scriptedSession(t, &scriptedConn{query: func(string) (driver.Rows, error) { return rows, nil }})
	encoded, failure := entry.execute(1, executeRequest{SQL: "SELECT ID FROM T", RowCap: 1})
	if failure != nil {
		t.Fatal(failure)
	}
	result := decodeResult(t, encoded)
	if *result.SessionLost || !result.IsTruncated || !reflect.DeepEqual(result.Rows, [][]string{{"1"}}) {
		t.Fatalf("result = %+v; want the truncated row on a kept session", result)
	}
}

func TestPingThatAnswersAfterItsCancelFailedIsConnectionLost(t *testing.T) {
	var entry *session
	entry = scriptedSession(t, &scriptedConn{ping: func() error {
		entry.cancel(1)
		waitFor(t, func() bool { return entry.currentState() == sessionLost })
		return nil
	}})
	assertKind(t, entry.ping(1), kindConnectionLost)
}

func TestPingOnAKeptSessionSucceeds(t *testing.T) {
	entry := scriptedSession(t, &scriptedConn{})
	if failure := entry.ping(1); failure != nil {
		t.Fatal(failure)
	}
}
