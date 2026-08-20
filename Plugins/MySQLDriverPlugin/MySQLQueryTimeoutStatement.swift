//
//  MySQLQueryTimeoutStatement.swift
//  MySQLDriverPlugin
//

internal func mysqlQueryTimeoutStatement(seconds: Int, isMariaDB: Bool) -> String {
    guard isMariaDB else {
        return "SET SESSION max_execution_time = \(seconds * 1_000)"
    }
    return "SET SESSION max_statement_time = \(seconds)"
}
