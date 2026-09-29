package hana

import (
	"cmp"
	"context"
	"crypto/rand"
	"database/sql"
	"slices"
	"strings"
)

const (
	planColumnName     = "QUERY PLAN"
	planColumnTypeName = "NVARCHAR"
	planIndentUnit     = "  "
)

type planNode struct {
	operatorID    int64
	parentID      int64
	hasParent     bool
	position      int64
	name          string
	details       string
	schema        string
	table         string
	outputSize    float64
	hasOutputSize bool
	cost          float64
	hasCost       bool
}

func newPlanStatementName() string {
	return "TABLEPRO_" + rand.Text()
}

func explainStatement(statementName string, statement string) string {
	return "EXPLAIN PLAN SET STATEMENT_NAME = " + quoteLiteral(statementName) + " FOR " + trimStatementTerminator(statement)
}

func planQuery(statementName string) string {
	return "SELECT OPERATOR_ID, PARENT_OPERATOR_ID, POSITION, OPERATOR_NAME, OPERATOR_DETAILS, SCHEMA_NAME, " +
		"TABLE_NAME, OUTPUT_SIZE, SUBTREE_COST FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = " +
		quoteLiteral(statementName) + " ORDER BY OPERATOR_ID"
}

func planCleanupStatement(statementName string) string {
	return "DELETE FROM SYS.EXPLAIN_PLAN_TABLE WHERE STATEMENT_NAME = " + quoteLiteral(statementName)
}

func quoteLiteral(text string) string {
	return "'" + strings.ReplaceAll(text, "'", "''") + "'"
}

func trimStatementTerminator(statement string) string {
	return strings.TrimRight(strings.TrimSpace(statement), "; \t\r\n")
}

func planEnvelope(lines []string) *resultEnvelope {
	envelope := tabularEnvelope([]columnInfo{{name: planColumnName, databaseTypeName: planColumnTypeName, textual: true}})
	for _, line := range lines {
		envelope.rows = append(envelope.rows, []cell{textCell(line)})
	}
	return envelope
}

func renderPlan(nodes []planNode) []string {
	indexByOperator := make(map[int64]int, len(nodes))
	for index, node := range nodes {
		if _, seen := indexByOperator[node.operatorID]; !seen {
			indexByOperator[node.operatorID] = index
		}
	}
	children := make(map[int][]int, len(nodes))
	var roots []int
	for index, node := range nodes {
		parentIndex, hasParent := indexByOperator[node.parentID]
		if !node.hasParent || !hasParent || parentIndex == index {
			roots = append(roots, index)
			continue
		}
		children[parentIndex] = append(children[parentIndex], index)
	}
	byPlanOrder := func(left, right int) int {
		return cmp.Or(cmp.Compare(nodes[left].position, nodes[right].position), cmp.Compare(nodes[left].operatorID, nodes[right].operatorID))
	}
	slices.SortStableFunc(roots, byPlanOrder)
	for parent := range children {
		slices.SortStableFunc(children[parent], byPlanOrder)
	}
	renderer := planRenderer{nodes: nodes, children: children, visited: make([]bool, len(nodes))}
	for _, root := range roots {
		renderer.walk(root, 0)
	}
	remaining := make([]int, 0, len(nodes))
	for index := range nodes {
		if !renderer.visited[index] {
			remaining = append(remaining, index)
		}
	}
	slices.SortStableFunc(remaining, func(left, right int) int {
		return cmp.Compare(nodes[left].operatorID, nodes[right].operatorID)
	})
	for _, index := range remaining {
		renderer.walk(index, 0)
	}
	return renderer.lines
}

type planRenderer struct {
	nodes    []planNode
	children map[int][]int
	visited  []bool
	lines    []string
}

func (r *planRenderer) walk(index int, depth int) {
	if r.visited[index] {
		return
	}
	r.visited[index] = true
	r.lines = append(r.lines, strings.Repeat(planIndentUnit, depth)+describePlanNode(r.nodes[index]))
	for _, child := range r.children[index] {
		r.walk(child, depth+1)
	}
}

func describePlanNode(node planNode) string {
	var text strings.Builder
	text.WriteString(singleLine(node.name))
	if details := singleLine(node.details); details != "" {
		text.WriteString(" ")
		text.WriteString(details)
	}
	if table := singleLine(node.table); table != "" {
		text.WriteString(" [table ")
		if schema := singleLine(node.schema); schema != "" {
			text.WriteString(schema)
			text.WriteString(".")
		}
		text.WriteString(table)
		text.WriteString("]")
	}
	if node.hasOutputSize {
		text.WriteString(" rows ")
		text.WriteString(formatFloat(node.outputSize, 64))
	}
	if node.hasCost {
		text.WriteString(" cost ")
		text.WriteString(formatFloat(node.cost, 64))
	}
	return text.String()
}

func singleLine(text string) string {
	return strings.Join(strings.Fields(text), " ")
}

func readPlan(conn *sql.Conn, op *operation, statementName string, statement string) (nodes []planNode, err error) {
	if _, err := conn.ExecContext(context.Background(), explainStatement(statementName, statement)); err != nil {
		return nil, err
	}
	if op.stopped() {
		return nil, errOperationStopped
	}
	rows, err := conn.QueryContext(context.Background(), planQuery(statementName))
	if err != nil {
		return nil, err
	}
	defer cleanupInto(&err, rows.Close)
	for rows.Next() {
		if op.stopped() {
			return nil, errOperationStopped
		}
		node, err := scanPlanNode(rows, op)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, node)
	}
	return nodes, rows.Err()
}

func scanPlanNode(rows *sql.Rows, op *operation) (planNode, error) {
	var operatorID, parentID, position sql.NullInt64
	var name, schema, table any
	var outputSize, cost sql.NullFloat64
	details := newLobCell(lobCellLimit, op.stopped)
	if err := rows.Scan(&operatorID, &parentID, &position, &name, details, &schema, &table, &outputSize, &cost); err != nil {
		return planNode{}, err
	}
	return planNode{
		operatorID:    operatorID.Int64,
		parentID:      parentID.Int64,
		hasParent:     parentID.Valid,
		position:      position.Int64,
		name:          textValue(name),
		details:       details.text(),
		schema:        textValue(schema),
		table:         textValue(table),
		outputSize:    outputSize.Float64,
		hasOutputSize: outputSize.Valid,
		cost:          cost.Float64,
		hasCost:       cost.Valid,
	}, nil
}

func textValue(value any) string {
	switch typed := value.(type) {
	case []byte:
		return decodeText(typed)
	case string:
		return decodeText([]byte(typed))
	default:
		return ""
	}
}
