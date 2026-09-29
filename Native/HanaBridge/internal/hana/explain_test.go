package hana

import (
	"reflect"
	"strings"
	"testing"
)

func child(operatorID, parentID, position int64, name string) planNode {
	return planNode{operatorID: operatorID, parentID: parentID, hasParent: true, position: position, name: name}
}

func TestPlanRendersDepthFirstInPositionOrder(t *testing.T) {
	nodes := []planNode{
		{operatorID: 1, name: "COLUMN SEARCH", details: "T.ID, T.NAME", hasOutputSize: true, outputSize: 1000, hasCost: true, cost: 0.0123},
		child(2, 1, 2, "JOIN"),
		child(3, 1, 1, "FILTER"),
		child(4, 2, 1, "COLUMN TABLE"),
		child(5, 2, 1, "ROW TABLE"),
		child(6, 3, 1, "LIMIT"),
	}
	nodes[3].schema, nodes[3].table = "APP", "ORDERS"
	nodes[4].table = "CUSTOMERS"
	want := []string{
		"COLUMN SEARCH T.ID, T.NAME rows 1000 cost 0.0123",
		"  FILTER",
		"    LIMIT",
		"  JOIN",
		"    COLUMN TABLE [table APP.ORDERS]",
		"    ROW TABLE [table CUSTOMERS]",
	}
	if got := renderPlan(nodes); !reflect.DeepEqual(got, want) {
		t.Fatalf("plan =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestPlanKeepsOrphansCyclesAndSeveralRoots(t *testing.T) {
	nodes := []planNode{
		child(10, 99, 1, "ORPHAN"),
		{operatorID: 1, name: "ROOT"},
		child(2, 3, 1, "LOOP A"),
		child(3, 2, 1, "LOOP B"),
		child(4, 4, 2, "SELF"),
	}
	got := renderPlan(nodes)
	if len(got) != len(nodes) {
		t.Fatalf("rendered %d lines for %d operators: %q", len(got), len(nodes), got)
	}
	want := []string{"ROOT", "ORPHAN", "SELF", "LOOP A", "  LOOP B"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("plan = %q; want %q", got, want)
	}
}

func TestPlanNodeTextStaysOnOneLine(t *testing.T) {
	node := planNode{name: "COLUMN SEARCH", details: "FILTER\n  CONDITION:\tA = 1\r\n", table: "T", hasCost: true, cost: 2}
	if got := describePlanNode(node); got != "COLUMN SEARCH FILTER CONDITION: A = 1 [table T] cost 2" {
		t.Fatalf("node text = %q", got)
	}
	if got := describePlanNode(planNode{name: "PROJECT"}); got != "PROJECT" {
		t.Fatalf("bare node text = %q", got)
	}
	if got := describePlanNode(planNode{name: "X", hasOutputSize: true, outputSize: 1e22}); got != "X rows 1e+22" {
		t.Fatalf("large size text = %q", got)
	}
}

func TestExplainStatementsUseTheGeneratedName(t *testing.T) {
	name := newPlanStatementName()
	if !strings.HasPrefix(name, "TABLEPRO_") || strings.ContainsAny(name, "' ") {
		t.Fatalf("statement name %q", name)
	}
	if other := newPlanStatementName(); other == name {
		t.Fatal("two plan statement names collided")
	}
	if got := explainStatement("TABLEPRO_X", "SELECT * FROM T;  \n"); got != "EXPLAIN PLAN SET STATEMENT_NAME = 'TABLEPRO_X' FOR SELECT * FROM T" {
		t.Fatalf("explain statement = %q", got)
	}
	if got := planQuery("TABLEPRO_X"); !strings.Contains(got, "FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = 'TABLEPRO_X' ORDER BY OPERATOR_ID") {
		t.Fatalf("plan query = %q", got)
	}
	if got := planCleanupStatement("TABLEPRO_X"); got != "DELETE FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = 'TABLEPRO_X'" {
		t.Fatalf("cleanup = %q", got)
	}
	if got := quoteLiteral("it's"); got != "'it''s'" {
		t.Fatalf("literal = %q", got)
	}
}

func TestPlanEnvelopeIsOneTextColumn(t *testing.T) {
	encoded := string(planEnvelope([]string{"ROOT", "  CHILD"}).appendJSON(nil))
	want := `{"columns":["QUERY PLAN"],"columnTypeNames":["NVARCHAR"],"columnClassifications":[null],"rows":[["ROOT"],["  CHILD"]],` +
		`"rowsAffected":0,"hasResultSet":true,"executionTime":0,"isTruncated":false,"truncatedLobCount":0,"sessionLost":false}`
	if encoded != want {
		t.Fatalf("plan envelope =\n%s\nwant\n%s", encoded, want)
	}
	empty := string(planEnvelope(nil).appendJSON(nil))
	if !strings.Contains(empty, `"rows":[]`) {
		t.Fatalf("empty plan = %s", empty)
	}
}
