package hana

import (
	"context"
	"database/sql"
	"fmt"

	hdb "github.com/SAP/go-hdb/driver"
)

func runStatement(conn *sql.Conn, op *operation, request executeRequest) (*resultEnvelope, error) {
	if op.stopped() {
		return nil, errOperationStopped
	}
	if request.hasParameters() {
		return runParameterized(conn, op, request)
	}
	if routesToExec(request.SQL) {
		return runCountingStatement(conn, request.SQL)
	}
	return runQuery(conn, op, request.SQL, request.rowLimit())
}

func runCountingStatement(conn *sql.Conn, statement string) (*resultEnvelope, error) {
	result, err := conn.ExecContext(context.Background(), statement)
	if err != nil {
		return nil, err
	}
	return affectedRowsEnvelope(rowsAffected(result)), nil
}

func runQuery(conn *sql.Conn, op *operation, statement string, rowLimit int) (envelope *resultEnvelope, err error) {
	rows, err := conn.QueryContext(context.Background(), statement)
	if err != nil {
		return nil, err
	}
	defer cleanupInto(&err, rows.Close)
	return readFirstResultSet(rows, op, rowLimit)
}

type preparedPlan struct {
	arguments   []any
	returnsRows bool
	bindsLob    bool
}

func runParameterized(conn *sql.Conn, op *operation, request executeRequest) (envelope *resultEnvelope, err error) {
	var metadata hdb.StmtMetadata
	statement, err := conn.PrepareContext(hdb.WithStmtMetadata(context.Background(), &metadata), request.SQL)
	if err != nil {
		return nil, err
	}
	plan, failure := planPreparedStatement(metadata, *request.Parameters)
	if failure != nil {
		return nil, joinCleanupFailure(failure, statement.Close())
	}
	if plan.bindsLob {
		if err := joinCleanupFailure(nil, statement.Close()); err != nil {
			return nil, err
		}
		return runInTransaction(conn, op, request, plan)
	}
	defer cleanupInto(&err, statement.Close)
	return runPrepared(statement, op, request.rowLimit(), plan)
}

func planPreparedStatement(metadata hdb.StmtMetadata, values []cell) (preparedPlan, *bridgeError) {
	if metadata == nil {
		return preparedPlan{}, internalError("the prepared statement carries no metadata")
	}
	parameters := describeParameters(metadata.ParameterTypes())
	if failure := refuseOutputParameters(parameters); failure != nil {
		return preparedPlan{}, failure
	}
	arguments, failure := bindParameters(values, parameters)
	if failure != nil {
		return preparedPlan{}, failure
	}
	return preparedPlan{
		arguments:   arguments,
		returnsRows: len(metadata.ColumnTypes()) > 0,
		bindsLob:    bindsLargeObject(parameters),
	}, nil
}

func runInTransaction(conn *sql.Conn, op *operation, request executeRequest, plan preparedPlan) (*resultEnvelope, error) {
	if op.stopped() {
		return nil, errOperationStopped
	}
	transaction, err := conn.BeginTx(context.Background(), nil)
	if err != nil {
		return nil, err
	}
	envelope, err := runTransactionStatement(transaction, op, request, plan)
	if err == nil && op.stopped() {
		err = errOperationStopped
	}
	if err != nil {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil {
			return nil, unsettledTransaction(err, rollbackErr)
		}
		return nil, err
	}
	if err := transaction.Commit(); err != nil {
		return nil, unsettledTransaction(nil, err)
	}
	return envelope, nil
}

func runTransactionStatement(transaction *sql.Tx, op *operation, request executeRequest, plan preparedPlan) (envelope *resultEnvelope, err error) {
	statement, err := transaction.PrepareContext(context.Background(), request.SQL)
	if err != nil {
		return nil, err
	}
	defer cleanupInto(&err, statement.Close)
	return runPrepared(statement, op, request.rowLimit(), plan)
}

func runPrepared(statement *sql.Stmt, op *operation, rowLimit int, plan preparedPlan) (envelope *resultEnvelope, err error) {
	if op.stopped() {
		return nil, errOperationStopped
	}
	if !plan.returnsRows {
		result, err := statement.ExecContext(context.Background(), plan.arguments...)
		if err != nil {
			return nil, err
		}
		return affectedRowsEnvelope(rowsAffected(result)), nil
	}
	rows, err := statement.QueryContext(context.Background(), plan.arguments...)
	if err != nil {
		return nil, err
	}
	defer cleanupInto(&err, rows.Close)
	return readFirstResultSet(rows, op, rowLimit)
}

func describeParameters(parameters []hdb.ParameterType) []parameterType {
	described := make([]parameterType, len(parameters))
	for index, parameter := range parameters {
		described[index] = describeParameter(parameter)
	}
	return described
}

func rowsAffected(result sql.Result) int64 {
	count, err := result.RowsAffected()
	if err != nil {
		return 0
	}
	return count
}

func readFirstResultSet(rows *sql.Rows, op *operation, rowLimit int) (*resultEnvelope, error) {
	for {
		columns, err := rows.Columns()
		if err != nil {
			return nil, err
		}
		if len(columns) > 0 {
			return readResultSet(rows, op, rowLimit)
		}
		if !rows.NextResultSet() {
			if err := rows.Err(); err != nil {
				return nil, err
			}
			return affectedRowsEnvelope(0), nil
		}
	}
}

func readResultSet(rows *sql.Rows, op *operation, rowLimit int) (*resultEnvelope, error) {
	columns, err := describeColumns(rows)
	if err != nil {
		return nil, err
	}
	envelope := tabularEnvelope(columns)
	for rows.Next() {
		if op.stopped() {
			return nil, errOperationStopped
		}
		if rowLimit > 0 && len(envelope.rows) >= rowLimit {
			envelope.isTruncated = true
			break
		}
		row, truncatedLobs, err := scanRow(rows, columns, op)
		if err != nil {
			return nil, err
		}
		envelope.rows = append(envelope.rows, row)
		envelope.truncatedLobCount += truncatedLobs
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return envelope, nil
}

func describeColumns(rows *sql.Rows) (columns []columnInfo, err error) {
	defer func() {
		if recovered := recover(); recovered != nil {
			columns = nil
			err = internalError(fmt.Sprintf("unsupported column type: %v", recovered))
		}
	}()
	columnTypes, err := rows.ColumnTypes()
	if err != nil {
		return nil, err
	}
	columns = make([]columnInfo, len(columnTypes))
	for index, columnType := range columnTypes {
		columns[index] = describeColumn(columnType)
	}
	return columns, nil
}

func scanRow(rows *sql.Rows, columns []columnInfo, op *operation) ([]cell, int, error) {
	values := make([]any, len(columns))
	lobs := make([]*lobCell, len(columns))
	destinations := make([]any, len(columns))
	for index, column := range columns {
		if column.isLob() {
			lobs[index] = newLobCell(lobCellLimit, op.stopped)
			destinations[index] = lobs[index]
			continue
		}
		destinations[index] = &values[index]
	}
	if err := rows.Scan(destinations...); err != nil {
		return nil, 0, err
	}
	row := make([]cell, len(columns))
	truncatedLobs := 0
	for index, column := range columns {
		lob := lobs[index]
		if lob == nil {
			row[index] = formatValue(values[index], column)
			continue
		}
		row[index] = lob.cell(column)
		if lob.truncated {
			truncatedLobs++
		}
	}
	return row, truncatedLobs, nil
}
