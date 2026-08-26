//
//  MySQLSelectLimitStatement.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum MySQLSelectLimitAction: Equatable {
    case none
    case apply(UInt64)
    case reset
}

internal struct MySQLBoundedFetchOutcome: Equatable {
    let keptRows: Int
    let isTruncated: Bool
    let serverIgnoredLimit: Bool
}

internal func mysqlSelectLimitStatement(rows: UInt64) -> String {
    "SET SQL_SELECT_LIMIT = \(rows)"
}

internal func mysqlSelectLimitResetStatement() -> String {
    "SET SQL_SELECT_LIMIT = DEFAULT"
}

/// The explicit `LIMIT` is what lets the probe answer while the session limit is 0, where an
/// unbounded `SELECT` would return no rows at all and read as a failed probe.
internal func mysqlSelectLimitProbeStatement() -> String {
    "SELECT @@sql_select_limit LIMIT 1"
}

internal func mysqlSelectLimitAction(applied: UInt64?, desired: UInt64?) -> MySQLSelectLimitAction {
    guard applied != desired else { return .none }
    guard let desired else { return .reset }
    return .apply(desired)
}

internal func mysqlClampedRowCap(_ rowCap: Int?) -> Int? {
    guard let rowCap, rowCap > 0 else { return nil }
    return min(rowCap, PluginRowLimits.emergencyMax)
}

/// One row past the cap, so a result that ends on its own still says whether more rows existed.
internal func mysqlSelectLimitRows(forRowCap rowCap: Int) -> UInt64 {
    UInt64(rowCap) + 1
}

private let mysqlStatementScanLimit = 10_000

/// Everything a row cap could bind, with comments, string literals and quoted identifiers removed so
/// a keyword spelled inside one is never read as syntax.
internal func mysqlStrippedStatementBody(_ sql: String) -> String {
    let source = Array(sql.prefix(mysqlStatementScanLimit).unicodeScalars)
    var body = String.UnicodeScalarView()
    var index = 0

    func peek(_ offset: Int) -> Unicode.Scalar? {
        let position = index + offset
        return position < source.count ? source[position] : nil
    }

    func skipToLineEnd() {
        while index < source.count, source[index] != "\n" { index += 1 }
    }

    func skipQuoted(by terminator: Unicode.Scalar) {
        index += 1
        while index < source.count {
            let scalar = source[index]
            if scalar == "\\", peek(1) != nil {
                index += 2
                continue
            }
            if scalar == terminator {
                if peek(1) == terminator {
                    index += 2
                    continue
                }
                index += 1
                return
            }
            index += 1
        }
    }

    while index < source.count {
        let scalar = source[index]
        switch scalar {
        case "-" where peek(1) == "-":
            skipToLineEnd()
        case "#":
            skipToLineEnd()
        case "/" where peek(1) == "*":
            index += 2
            while index < source.count, !(source[index] == "*" && peek(1) == "/") { index += 1 }
            index = min(index + 2, source.count)
            body.append(" ")
        case "'", "\"", "`":
            skipQuoted(by: scalar)
            body.append(" ")
        default:
            body.append(scalar)
            index += 1
        }
    }

    return String(body)
}

private func mysqlBodyMatches(_ body: String, _ pattern: String) -> Bool {
    body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

/// Installing the cap costs a `SET`, and a `SET` resets what `ROW_COUNT()` reports, so
/// `UPDATE t SET ...; SELECT ROW_COUNT()` answered 0 rather than the UPDATE's count. Measured on
/// MariaDB 12.3.2 and MySQL 8.4.11. A statement that can only ever return one row cannot be bound by
/// any cap, so it is left to run against the session exactly as it stands.
///
/// Answering false when the statement really is single-row costs a redundant `SET`. Answering true
/// when it is not would leave a cap unreconciled, which is why the caller only trusts this while it
/// holds no limit of its own.
internal func mysqlStatementReturnsAtMostOneRow(_ sql: String) -> Bool {
    let body = mysqlStrippedStatementBody(sql)
    guard mysqlBodyMatches(body, "^\\s*SELECT\\b") else { return false }
    guard !mysqlBodyMatches(body, "\\b(UNION|INTERSECT|EXCEPT)\\b") else { return false }
    guard !mysqlBodyMatches(body, "\\bVALUES\\b") else { return false }
    guard let fromRange = body.range(
        of: "\\bFROM\\b", options: [.regularExpression, .caseInsensitive]
    ) else {
        return true
    }
    return mysqlBodyMatches(String(body[fromRange.lowerBound...]), "^FROM\\s+DUAL\\s*$")
}

internal func mysqlBoundedFetchOutcome(
    fetchedRows: Int,
    rowCap: Int,
    serverSentMore: Bool
) -> MySQLBoundedFetchOutcome {
    let truncated = serverSentMore || fetchedRows > rowCap
    return MySQLBoundedFetchOutcome(
        keptRows: truncated ? rowCap : fetchedRows,
        isTruncated: truncated,
        serverIgnoredLimit: serverSentMore
    )
}
