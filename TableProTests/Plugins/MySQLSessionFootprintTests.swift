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

    /// mysqldump writes its whole preamble as version-gated comments, which MySQL executes: eight
    /// `@OLD_` variables and the character set, time zone and check settings, plus one
    /// `@saved_cs_client` per table. They read as comments, so the statement splitter used to
    /// drop them and a restore run from the editor left a session the footprint called clean.
    @Test("A version-gated comment sets session state, and is seen")
    func versionGatedCommentsAreSeen() {
        let preamble = """
        /*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
        /*!40103 SET TIME_ZONE='+00:00' */;
        INSERT INTO `t` VALUES (1);
        """
        let result = footprint(after: preamble)
        #expect(result.hasUserVariables)
        #expect(result.hasSessionSettings)
        #expect(result.blockingReason != nil)

        #expect(footprint(after: "/*M!100301 SET @x = 1 */").hasUserVariables)
        #expect(footprint(after: "/*! SET SESSION sql_mode = 'ANSI' */").hasSessionSettings)
    }

    /// Only a statement that is entirely one of them. A version-gated comment inside a `CREATE
    /// TABLE`, which is how mysqldump writes a partition clause, is part of that statement.
    @Test("A version-gated comment inside another statement is left alone")
    func versionGatedCommentsInsideAStatementAreLeftAlone() {
        #expect(footprint(after: "CREATE TABLE t (a INT) /*!50100 PARTITION BY HASH (a) */").isClean)
        #expect(footprint(after: "SELECT '/*!40101 SET NAMES utf8 */'").isClean)
    }

    /// `USE` moves the session to another database, and a reconnect puts it back on the one the
    /// driver holds without saying so. Measured on MySQL 8.4.11: after the connection was killed,
    /// `SELECT DATABASE()` answered the connection's own database, not the one `USE` had selected.
    @Test("A database switched with USE is tracked")
    func useIsTracked() {
        let result = footprint(after: "USE reporting")
        #expect(result.hasChangedDatabase)
        #expect(result.blockingReason != nil)
        #expect(footprint(after: "SELECT * FROM t USE INDEX (i)").isClean)
    }

    /// The two gates read different things: the replay asks `isClean` and the idle release asks
    /// `blockingReason`. A flag added without an arm in the ladder would tighten one and leave
    /// the other handing the connection back.
    @Test("Every flag that makes the footprint dirty also gives a reason")
    func everyFlagGivesAReason() {
        for statement in [
            "CREATE TEMPORARY TABLE staging (a INT)",
            "SET @total = 5",
            "PREPARE stmt FROM 'SELECT 1'",
            "SELECT GET_LOCK('job', 10)",
            "LOCK TABLES users WRITE",
            "FLUSH TABLES WITH READ LOCK",
            "HANDLER users OPEN",
            "SET SESSION sql_mode = 'ANSI'",
            "USE reporting",
            "CALL rebuild_report()",
        ] {
            let result = footprint(after: statement)
            #expect(result.isClean == (result.blockingReason == nil), "\(statement)")
            #expect(!result.isClean, "\(statement)")
        }
        var open = MySQLSessionFootprint()
        open.observeServerTransaction(isOpen: true)
        #expect(open.isClean == (open.blockingReason == nil))
    }

    /// The server answers this one itself, in the status flags of every reply, and it is exact
    /// where the text is a guess. Measured on MySQL 8.4.11: `SET autocommit = 0` followed by a
    /// plain `SELECT` reports a transaction that appears nowhere in the statements.
    @Test("The server's own transaction flag wins over what the text said")
    func serverTransactionFlagWins() {
        var result = footprint(after: "SELECT 1")
        result.observeServerTransaction(isOpen: true)
        #expect(result.hasOpenTransaction)
        #expect(!result.isClean)

        var closed = footprint(after: "BEGIN")
        #expect(closed.hasOpenTransaction)
        closed.observeServerTransaction(isOpen: false)
        #expect(closed.isClean)
    }

    /// A transaction opened inside a version-gated comment runs on the server. Measured on MySQL
    /// 8.4.11 through `information_schema.INNODB_TRX`: `/*!40101 BEGIN */` then an `INSERT` leaves
    /// one transaction open, and a `ROLLBACK` discards the row.
    @Test("A transaction opened inside a version-gated comment is seen")
    func versionGatedTransactionsAreSeen() {
        #expect(footprint(after: "/*!40101 BEGIN */").hasOpenTransaction)
        #expect(footprint(after: "/*!40101 START TRANSACTION */").hasOpenTransaction)
        #expect(footprint(after: "/*!40101 BEGIN */", "/*!40101 COMMIT */").isClean)
    }

    /// `FLUSH TABLES WITH READ LOCK` takes a lock that is the session's alone, and the session
    /// holding one is idle by design while a backup copies files, which is exactly when the idle
    /// release fires. Measured on MySQL 8.4.11: a writer got error 1205 while it was held, and
    /// the same write went through the moment the holding connection was killed.
    @Test("A global read lock and an open HANDLER block a release")
    func locksOutsideLockTablesAreTracked() {
        #expect(footprint(after: "FLUSH TABLES WITH READ LOCK").hasLockedTables)
        #expect(footprint(after: "FLUSH TABLES users, orders FOR EXPORT").hasLockedTables)
        #expect(footprint(after: "FLUSH PRIVILEGES").isClean)
        #expect(footprint(after: "HANDLER users OPEN").hasOpenHandlers)
        #expect(footprint(after: "HANDLER users READ FIRST").hasOpenHandlers)
    }

    /// The prefix checks used to run against the raw text, so one extra space or a line break
    /// between the keywords hid the statement completely.
    @Test("Whitespace between the keywords does not hide a statement")
    func whitespaceDoesNotHideAStatement() {
        #expect(footprint(after: "CREATE  TEMPORARY TABLE staging (a INT)").hasTemporaryTables)
        #expect(footprint(after: "CREATE TEMPORARY\nTABLE staging (a INT)").hasTemporaryTables)
        #expect(footprint(after: "PREPARE\n stmt FROM 'SELECT 1'").hasPreparedStatements)
        #expect(footprint(after: "SET\n  @x = 1").hasUserVariables)
    }

    /// A dump line that carries a note after its version-gated comment, or two of them on one
    /// line, is still a statement the server runs.
    @Test("Text after a version-gated comment does not hide what it ran")
    func trailingTextAfterAVersionGatedComment() {
        #expect(footprint(after: "/*!40101 SET @x = 1 */ -- saved").hasUserVariables)
        #expect(footprint(after: "/*!40101 SET @x = 1 */ /*!40103 SET @y = 2 */").hasUserVariables)
        #expect(footprint(after: "/*!40101 SET @x = 1").isClean)
    }

    /// `@@` is a system variable under another spelling. The release is blocked either way; the
    /// reason the user reads should be the right one.
    @Test("A system variable set with @@ reads as a session setting")
    func systemVariablesAreNotUserVariables() {
        let result = footprint(after: "SET @@SESSION.sql_mode = 'ANSI'")
        #expect(result.hasSessionSettings)
        #expect(!result.hasUserVariables)
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
