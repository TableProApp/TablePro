//
//  MySQLSelectLimitTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing

@Suite("MySQL Server-Side Row Cap")
struct MySQLSelectLimitTests {
    @Test("The statement asks for one row past the cap")
    func statementAsksForOneRowPastTheCap() {
        let statement = mysqlSelectLimitStatement(rows: mysqlSelectLimitRows(forRowCap: 1_000))
        #expect(statement == "SET SQL_SELECT_LIMIT = 1001")
    }

    @Test("The reset restores the server default rather than a number")
    func resetRestoresTheServerDefault() {
        #expect(mysqlSelectLimitResetStatement() == "SET SQL_SELECT_LIMIT = DEFAULT")
    }

    @Test("A cap is clamped to the emergency ceiling and a missing cap stays missing")
    func capIsClamped() {
        #expect(mysqlClampedRowCap(1_000) == 1_000)
        #expect(mysqlClampedRowCap(nil) == nil)
        #expect(mysqlClampedRowCap(0) == nil)
        #expect(mysqlClampedRowCap(-1) == nil)
        #expect(mysqlClampedRowCap(PluginRowLimits.emergencyMax + 1) == PluginRowLimits.emergencyMax)
    }

    @Test("Reconciling to the value already applied issues nothing")
    func alreadyAppliedIssuesNothing() {
        #expect(mysqlSelectLimitAction(applied: 1_001, desired: 1_001) == .none)
        #expect(mysqlSelectLimitAction(applied: nil, desired: nil) == .none)
    }

    @Test("Reconciling to a different cap applies it")
    func differentCapIsApplied() {
        #expect(mysqlSelectLimitAction(applied: nil, desired: 1_001) == .apply(1_001))
        #expect(mysqlSelectLimitAction(applied: 1_001, desired: 501) == .apply(501))
    }

    /// The reset is what keeps a capped read from truncating the next `information_schema` query on
    /// the same connection, so an uncapped statement after a capped one must always issue it.
    @Test("Reconciling to no cap resets the session")
    func noCapResetsTheSession() {
        #expect(mysqlSelectLimitAction(applied: 1_001, desired: nil) == .reset)
    }

    @Test("A result inside the cap is not truncated")
    func resultInsideTheCapIsNotTruncated() {
        let outcome = mysqlBoundedFetchOutcome(fetchedRows: 42, rowCap: 1_000, serverSentMore: false)
        #expect(outcome.keptRows == 42)
        #expect(outcome.isTruncated == false)
        #expect(outcome.serverIgnoredLimit == false)
    }

    @Test("A result of exactly the cap is not truncated")
    func exactlyTheCapIsNotTruncated() {
        let outcome = mysqlBoundedFetchOutcome(fetchedRows: 1_000, rowCap: 1_000, serverSentMore: false)
        #expect(outcome.keptRows == 1_000)
        #expect(outcome.isTruncated == false)
    }

    /// The server is asked for `cap + 1`, so the extra row arriving is the only signal that more rows
    /// existed. It is counted and then dropped.
    @Test("One row past the cap means truncated, and that row is dropped")
    func oneRowPastTheCapMeansTruncated() {
        let outcome = mysqlBoundedFetchOutcome(fetchedRows: 1_001, rowCap: 1_000, serverSentMore: false)
        #expect(outcome.keptRows == 1_000)
        #expect(outcome.isTruncated == true)
        #expect(outcome.serverIgnoredLimit == false)
    }

    /// `CALL`, and a statement carrying its own larger `LIMIT`, are not bounded by the session
    /// variable, so the client still has to stop the read and the server still has to be told.
    @Test("Rows arriving past the requested limit mean the server ignored it")
    func serverIgnoringTheLimitIsReported() {
        let outcome = mysqlBoundedFetchOutcome(fetchedRows: 1_001, rowCap: 1_000, serverSentMore: true)
        #expect(outcome.keptRows == 1_000)
        #expect(outcome.isTruncated == true)
        #expect(outcome.serverIgnoredLimit == true)
    }

    @Test("A cap of one keeps one row and still detects more")
    func capOfOne() {
        #expect(mysqlBoundedFetchOutcome(fetchedRows: 1, rowCap: 1, serverSentMore: false).isTruncated == false)
        let overflow = mysqlBoundedFetchOutcome(fetchedRows: 2, rowCap: 1, serverSentMore: false)
        #expect(overflow.keptRows == 1)
        #expect(overflow.isTruncated == true)
    }

    @Test("An empty result is not truncated")
    func emptyResultIsNotTruncated() {
        let outcome = mysqlBoundedFetchOutcome(fetchedRows: 0, rowCap: 1_000, serverSentMore: false)
        #expect(outcome.keptRows == 0)
        #expect(outcome.isTruncated == false)
    }

    /// Installing the cap costs a `SET`, and a `SET` resets what `ROW_COUNT()` reports, so
    /// `UPDATE t SET ...; SELECT ROW_COUNT()` answered 0 instead of the UPDATE's count. Measured on
    /// MariaDB 12.3.2 and MySQL 8.4.11.
    @Test("A single-row expression needs no server-side cap")
    func singleRowExpressionsNeedNoCap() {
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT ROW_COUNT()"))
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT LAST_INSERT_ID()"))
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT 1"))
        #expect(mysqlStatementReturnsAtMostOneRow("  select  @@sql_select_limit  "))
    }

    /// `FROM DUAL` is MySQL's own spelling for "no table", so it stays a single-row expression.
    @Test("FROM DUAL is still a single-row expression")
    func fromDualIsSingleRow() {
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT ROW_COUNT() FROM DUAL"))
        #expect(mysqlStatementReturnsAtMostOneRow("select 1 from dual"))
    }

    @Test("A statement that reads a table is not a single-row expression")
    func tableReadsAreNotSingleRow() {
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT * FROM big") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("select id\nfrom events\nwhere id > 1") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT a FROM(SELECT 1 AS a) t") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("WITH x AS (SELECT * FROM t) SELECT * FROM x") == false)
    }

    /// The reviewed draft skipped the cap for anything without a `FROM`, which left a stale cap
    /// installed in front of a multi-row constant query and reported the short result as complete.
    @Test("A set operation or VALUES is not a single-row expression even with no FROM")
    func setOperationsAreNotSingleRow() {
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT 1 UNION ALL SELECT 2") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT 1 UNION SELECT 2") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("VALUES ROW(1), ROW(2)") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("TABLE big") == false)
    }

    /// A keyword inside a comment or a literal is text, not syntax.
    @Test("A keyword inside a comment or a literal is not read as syntax")
    func commentsAndLiteralsAreNotSyntax() {
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT ROW_COUNT() /* FROM the prior update */"))
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT ROW_COUNT(), 'FROM'"))
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT ROW_COUNT() -- FROM big"))
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT ROW_COUNT() # UNION ALL SELECT 2"))
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT `from`, `union`"))
        #expect(mysqlStatementReturnsAtMostOneRow("SELECT 'it''s FROM here'"))
    }

    @Test("A statement that is not a SELECT is never treated as a single-row expression")
    func nonSelectStatementsAreNotSingleRow() {
        #expect(mysqlStatementReturnsAtMostOneRow("UPDATE t SET v = 1") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("SHOW WARNINGS") == false)
        #expect(mysqlStatementReturnsAtMostOneRow("") == false)
    }

    @Test("Stripping removes comments and quoted text and keeps the rest")
    func strippingRemovesQuotedText() {
        #expect(mysqlStrippedStatementBody("SELECT 1 -- FROM big").contains("FROM") == false)
        #expect(mysqlStrippedStatementBody("SELECT /* FROM */ 1").contains("FROM") == false)
        #expect(mysqlStrippedStatementBody("SELECT 'FROM' FROM t").contains("FROM"))
    }

    /// The probe carries its own `LIMIT` so it still answers when the session limit is 0, where an
    /// unbounded read would return no rows and read as a failed probe.
    @Test("The baseline probe carries its own LIMIT")
    func baselineProbeCarriesItsOwnLimit() {
        #expect(mysqlSelectLimitProbeStatement() == "SELECT @@sql_select_limit LIMIT 1")
    }
}
