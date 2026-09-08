//
//  MySQLSessionFootprintTests.swift
//  TableProTests
//
//  Tests for MySQLSessionFootprint and MySQLIdleRelease (compiled via project.yml from
//  MySQLDriverPlugin).
//

import Foundation
import Testing

@Suite("MySQL session footprint")
struct MySQLSessionFootprintTests {
    private func footprint(after statements: String...) -> MySQLSessionFootprint {
        var footprint = MySQLSessionFootprint()
        for statement in statements {
            footprint.observe(statement)
        }
        return footprint
    }

    @Test("A session that has only read is clean")
    func readsLeaveNoFootprint() {
        let result = footprint(after: "SELECT 1", "SELECT * FROM users WHERE id = 3", "SHOW TABLES")
        #expect(result.isClean)
        #expect(result.blockingReason == nil)
    }

    /// Each of these is destroyed by a reconnect. Measured against MySQL 8.4.11 and MariaDB
    /// 12.3.3: the temporary table, the user variable, the prepared statement and the advisory
    /// lock are all gone, and the transaction rolls back reporting success.
    @Test("Each kind of session state blocks a release on its own")
    func eachKindBlocks() {
        #expect(footprint(after: "CREATE TEMPORARY TABLE staging (a INT)").hasTemporaryTables)
        #expect(footprint(after: "SET @total = 5").hasUserVariables)
        #expect(footprint(after: "PREPARE stmt FROM 'SELECT 1'").hasPreparedStatements)
        #expect(footprint(after: "SELECT GET_LOCK('job', 10)").hasAdvisoryLocks)
        #expect(footprint(after: "LOCK TABLES users WRITE").hasLockedTables)
        #expect(footprint(after: "SET SESSION sql_mode = 'ANSI'").hasSessionSettings)
        #expect(footprint(after: "BEGIN").hasOpenTransaction)

        for statement in [
            "CREATE TEMPORARY TABLE staging (a INT)",
            "SET @total = 5",
            "PREPARE stmt FROM 'SELECT 1'",
            "SELECT GET_LOCK('job', 10)",
            "LOCK TABLES users WRITE",
            "SET SESSION sql_mode = 'ANSI'",
            "BEGIN",
        ] {
            #expect(footprint(after: statement).blockingReason != nil, "\(statement)")
        }
    }

    @Test("Committing clears the transaction, and unlocking clears the table locks")
    func endingsClearWhatTheyEnd() {
        #expect(footprint(after: "BEGIN", "INSERT INTO t VALUES (1)", "COMMIT").isClean)
        #expect(footprint(after: "LOCK TABLES users WRITE", "UNLOCK TABLES").isClean)
        #expect(footprint(after: "SELECT GET_LOCK('job', 10)", "SELECT RELEASE_ALL_LOCKS()").isClean)
    }

    /// A global setting outlives the connection, so it is not the session's to lose and must not
    /// keep the connection alive forever.
    @Test("A global setting does not block, but a bare SET does")
    func globalSettingsDoNotBlock() {
        #expect(footprint(after: "SET GLOBAL max_connections = 200").isClean)
        #expect(footprint(after: "SET @@GLOBAL.max_connections = 200").isClean)
        #expect(footprint(after: "SET sql_mode = 'ANSI'").hasSessionSettings)
        #expect(footprint(after: "SET NAMES utf8mb4").hasSessionSettings)
    }

    /// `SELECT ... INTO @x` writes a user variable without a leading `SET`, and losing it silently
    /// is the same defect as losing one that was set.
    @Test("A variable written by SELECT INTO is tracked too")
    func selectIntoWritesAUserVariable() {
        #expect(footprint(after: "SELECT count(*) INTO @n FROM users").hasUserVariables)
    }

    /// A routine's body never reaches this driver, and it is free to create a temporary table,
    /// take a lock or open a transaction. Opaque is the only honest reading, and it errs toward
    /// keeping the connection.
    @Test("A stored routine call is treated as opaque")
    func callsAreOpaque() {
        let result = footprint(after: "CALL rebuild_report()")
        #expect(result.ranOpaqueRoutine)
        #expect(result.blockingReason != nil)
    }

    /// A comment in front of a statement pushed the keyword off the front, so the prefix checks
    /// found nothing and the session read as clean. A release then dropped the temporary table.
    @Test("A comment in front of a statement does not hide it")
    func leadingCommentsDoNotHideState() {
        #expect(footprint(after: "-- staging\nCREATE TEMPORARY TABLE staging (a INT)").hasTemporaryTables)
        #expect(footprint(after: "/* setup */ SET @total = 5").hasUserVariables)
        #expect(footprint(after: "# note\nPREPARE stmt FROM 'SELECT 1'").hasPreparedStatements)
        #expect(footprint(after: "-- lock it\nLOCK TABLES users WRITE").hasLockedTables)
    }

    /// The driver's query timeout is a `SET SESSION`, and `DatabaseManager` applies it on every
    /// connect. Counting it would leave the footprint dirty before the user ran anything, and no
    /// connection would ever be released.
    @Test("A semicolon inside a literal does not split a statement")
    func semicolonsInsideLiteralsAreNotSeparators() {
        #expect(footprint(after: "SELECT ';CREATE TEMPORARY TABLE x (a INT);'").isClean)
        #expect(footprint(after: "INSERT INTO t VALUES ('SET @x = 1')").isClean)
    }

    @Test("A variable assigned with := is tracked")
    func walrusAssignmentIsTracked() {
        #expect(footprint(after: "SELECT @counter := 1").hasUserVariables)
    }

    @Test("A reset clears everything, for a session that is genuinely new")
    func resetClearsEverything() {
        var result = footprint(after: "BEGIN", "CREATE TEMPORARY TABLE staging (a INT)")
        #expect(!result.isClean)
        result.reset()
        #expect(result.isClean)
    }
}

@Suite("MySQL idle release policy")
struct MySQLIdleReleaseTests {
    @Test("Anything that is not a positive number of minutes means never")
    func malformedValuesMeanNever() {
        for value in [nil, "", "  ", "0", "-5", "soon"] {
            #expect(MySQLIdleRelease.minutes(fromFieldValue: value) == nil, "\(value ?? "nil")")
        }
    }

    @Test("A positive number of minutes becomes that interval, clamped to the maximum")
    func positiveValuesParse() {
        #expect(MySQLIdleRelease.interval(fromFieldValue: "10") == .seconds(600))
        #expect(MySQLIdleRelease.minutes(fromFieldValue: "9999") == MySQLIdleRelease.maximumMinutes)
    }

    @Test("The field's default value parses as never")
    func defaultValueIsNever() {
        #expect(MySQLIdleRelease.minutes(fromFieldValue: MySQLIdleRelease.neverValue) == nil)
    }
}
