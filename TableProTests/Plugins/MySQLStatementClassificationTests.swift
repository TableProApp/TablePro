//
//  MySQLStatementClassificationTests.swift
//  TableProTests
//

import Testing

@Suite("MySQL Statement Classification")
struct MySQLStatementClassificationTests {
    @Test("SELECT is read-only")
    func selectIsReadOnly() {
        #expect(mysqlStatementIsReadOnly("SELECT * FROM users"))
    }

    @Test("Leading whitespace and lowercase are handled")
    func whitespaceAndCase() {
        #expect(mysqlStatementIsReadOnly("   \n select 1"))
    }

    @Test("SHOW, DESCRIBE, and DESC are read-only")
    func showAndDescribe() {
        #expect(mysqlStatementIsReadOnly("SHOW TABLES"))
        #expect(mysqlStatementIsReadOnly("DESCRIBE users"))
        #expect(mysqlStatementIsReadOnly("DESC users"))
    }

    @Test("Mutating statements are not read-only")
    func mutatingStatements() {
        #expect(!mysqlStatementIsReadOnly("INSERT INTO users VALUES (1)"))
        #expect(!mysqlStatementIsReadOnly("UPDATE users SET name = 'a'"))
        #expect(!mysqlStatementIsReadOnly("DELETE FROM users"))
        #expect(!mysqlStatementIsReadOnly("CALL do_work()"))
        #expect(!mysqlStatementIsReadOnly("REPLACE INTO users VALUES (1)"))
        #expect(!mysqlStatementIsReadOnly("DROP TABLE users"))
    }

    @Test("A statement behind a leading comment is treated conservatively")
    func leadingCommentIsConservative() {
        #expect(!mysqlStatementIsReadOnly("/* note */ SELECT 1"))
        #expect(!mysqlStatementIsReadOnly("-- note\nSELECT 1"))
    }

    @Test("An empty statement is not read-only")
    func emptyIsNotReadOnly() {
        #expect(!mysqlStatementIsReadOnly(""))
        #expect(!mysqlStatementIsReadOnly("   "))
    }
}

@Suite("MySQL Replay Safety")
struct MySQLReplaySafetyTests {
    /// The only caller asks this to decide whether to run a statement a second time after the
    /// connection dropped, so a plain read is the only thing that may say yes.
    @Test("A plain read is safe to replay")
    func plainReadIsSafeToReplay() {
        #expect(mysqlStatementIsSafeToReplay("SELECT * FROM users"))
        #expect(mysqlStatementIsSafeToReplay("SHOW TABLES"))
        #expect(mysqlStatementIsSafeToReplay("DESCRIBE users"))
    }

    @Test("A write is never replayed")
    func writesAreNeverReplayed() {
        #expect(mysqlStatementIsSafeToReplay("UPDATE users SET name = 'a'") == false)
        #expect(mysqlStatementIsSafeToReplay("INSERT INTO users VALUES (1)") == false)
        #expect(mysqlStatementIsSafeToReplay("CALL do_work()") == false)
    }

    /// MariaDB sequences advance on read, so a replay hands out a value the user never sees.
    @Test("A sequence read is not replayed")
    func sequenceReadsAreNotReplayed() {
        #expect(mysqlStatementIsSafeToReplay("SELECT NEXTVAL(order_seq)") == false)
        #expect(mysqlStatementIsSafeToReplay("select nextval(order_seq)") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT SETVAL(order_seq, 100)") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT NEXT VALUE FOR order_seq") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT PREVIOUS VALUE FOR order_seq") == false)
    }

    @Test("A lock function is not replayed")
    func lockFunctionsAreNotReplayed() {
        #expect(mysqlStatementIsSafeToReplay("SELECT GET_LOCK('job', 10)") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT RELEASE_LOCK('job')") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT RELEASE_ALL_LOCKS()") == false)
    }

    @Test("A read that takes row locks is not replayed")
    func rowLockingReadsAreNotReplayed() {
        #expect(mysqlStatementIsSafeToReplay("SELECT * FROM users FOR UPDATE") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT * FROM users LOCK IN SHARE MODE") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT * FROM users FOR SHARE") == false)
    }

    @Test("A read that writes somewhere is not replayed")
    func readsThatWriteAreNotReplayed() {
        #expect(mysqlStatementIsSafeToReplay("SELECT * FROM users INTO OUTFILE '/tmp/u'") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT * FROM users INTO DUMPFILE '/tmp/u'") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT id INTO @last FROM users") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT @counter := @counter + 1") == false)
    }

    @Test("A read whose value moves on its own is not replayed")
    func nonRepeatableReadsAreNotReplayed() {
        #expect(mysqlStatementIsSafeToReplay("SELECT UUID_SHORT()") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT MASTER_POS_WAIT('log', 4)") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT SLEEP(30)") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT BENCHMARK(1000000, MD5('x'))") == false)
    }

    /// Line breaks between the words must not hide the marker.
    @Test("Whitespace between the words does not hide a marker")
    func whitespaceDoesNotHideAMarker() {
        #expect(mysqlStatementIsSafeToReplay("SELECT *\n  FROM users\n  FOR   UPDATE") == false)
        #expect(mysqlStatementIsSafeToReplay("SELECT NEXT\n VALUE\tFOR order_seq") == false)
    }

    private func footprint(after statements: String...) -> MySQLSessionFootprint {
        var footprint = MySQLSessionFootprint()
        for statement in statements {
            footprint.observe(statement)
        }
        return footprint
    }

    /// The session that replaces a dropped one is a new one, and the statement is answered from
    /// it. Measured on MySQL 8.4.11: `SELECT @probe` came back `NULL` where it had come back 42,
    /// with nothing raised. A replay is therefore only for a session holding nothing.
    @Test("A read is replayed only on a session that holds nothing")
    func replayNeedsACleanSession() {
        #expect(mysqlMayReplay("SELECT * FROM users", on: footprint(after: "SELECT 1")))

        for statement in [
            "SET @total = 5",
            "SET SESSION sql_mode = 'ANSI'",
            "CREATE TEMPORARY TABLE staging (a INT)",
            "PREPARE stmt FROM 'SELECT 1'",
            "LOCK TABLES users WRITE",
            "FLUSH TABLES WITH READ LOCK",
            "HANDLER users OPEN",
            "USE reporting",
            "BEGIN",
            "/*!40101 BEGIN */",
            "CALL rebuild_report()",
            "/*!40103 SET TIME_ZONE='+00:00' */",
        ] {
            #expect(!mysqlMayReplay("SELECT * FROM users", on: footprint(after: statement)), "\(statement)")
        }

        var serverSideTransaction = MySQLSessionFootprint()
        serverSideTransaction.observeServerTransaction(isOpen: true)
        #expect(!mysqlMayReplay("SELECT * FROM users", on: serverSideTransaction))
    }

    /// These change nothing, so the footprint stays clean, and their answer still belongs to the
    /// session that ran the statement before them. Measured on MySQL 8.4.11: a fresh connection
    /// answers `SELECT LAST_INSERT_ID()` with `0`, so an `INSERT`, a dropped connection and a
    /// replayed read showed `0` for a row that had an id.
    @Test("A read of a session-scoped value is never replayed")
    func sessionScopedReadsAreNotReplayed() {
        for query in [
            "SELECT LAST_INSERT_ID()",
            "SELECT ROW_COUNT()",
            "SELECT FOUND_ROWS()",
            "SELECT CONNECTION_ID()",
            "select last_insert_id()",
        ] {
            #expect(!mysqlMayReplay(query, on: MySQLSessionFootprint()), "\(query)")
        }
    }

    @Test("A statement that is unsafe on its own is not replayed on a clean session either")
    func replayStillNeedsASafeStatement() {
        #expect(!mysqlMayReplay("UPDATE users SET name = 'a'", on: MySQLSessionFootprint()))
        #expect(!mysqlMayReplay("SELECT GET_LOCK('job', 10)", on: MySQLSessionFootprint()))
    }
}
