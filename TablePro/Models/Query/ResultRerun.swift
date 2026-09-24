//
//  ResultRerun.swift
//  TablePro
//

import Foundation

/// A statement as the editor holds it, `:name` placeholders and all, with the values its run bound to them.
///
/// A parameterized result is run again from this form, not from the driver's `?` or `$1` text and its list of values.
/// An edit such as replacing the statement's own ORDER BY can remove a placeholder from that text while its value
/// stays in the list, and every later value then lands one place early. Converting this form after the edit reads
/// the placeholders and their values from the same text, so the two cannot disagree.
struct NamedParameterStatement: Equatable, Sendable {
    let sql: String
    let parameters: [QueryParameter]
}

/// What running a query result again sends.
enum ResultRerun: Equatable {
    case statement(String)
    /// Bound to the values the result ran with, not to whatever the parameter panel holds now.
    case parameterized(NamedParameterStatement)

    var sql: String {
        switch self {
        case .statement(let sql):
            sql
        case .parameterized(let statement):
            statement.sql
        }
    }

    var boundParameters: [QueryParameter]? {
        guard case .parameterized(let statement) = self else { return nil }
        return statement.parameters
    }

    func transformingSQL(_ transform: (String) -> String) -> ResultRerun {
        switch self {
        case .statement(let sql):
            .statement(transform(sql))
        case .parameterized(let statement):
            .parameterized(NamedParameterStatement(sql: transform(statement.sql), parameters: statement.parameters))
        }
    }
}

extension QueryTab {
    /// What a header click on this tab's result runs again, before the grid's ORDER BY goes on it.
    ///
    /// The result's own statement, never the editor text it came from, which can hold other statements, writes
    /// included. Read from the result rather than from `pagination`, because Fetch All clears the pagination copy once
    /// it has every row. Nil when the result has no statement of its own to run, such as one a SQL Server batch
    /// returned, or positional values with no named statement beside them: those rows are sorted where they are. A tab
    /// showing no result has only its own query to go on.
    @MainActor
    var sortRerun: ResultRerun? {
        guard let result = display.activeResultSet else {
            return .statement(pagination.baseQueryForMore ?? content.query)
        }
        if let statement = result.namedParameterStatement {
            return .parameterized(statement)
        }
        guard let baseQuery = result.baseQuery, result.baseQueryParameterValues?.isEmpty ?? true else { return nil }
        return .statement(baseQuery)
    }
}
