//
//  PostgreSQLSessionScopeSQLTests.swift
//  TableProTests
//

import TableProPluginKit
import Testing

struct PostgreSQLSessionScopeSQLTests {
    private static func setting(_ name: String, _ value: String?) -> PluginSessionSetting {
        PluginSessionSetting(name: name, value: value)
    }

    @Test("Preserve covers every SET a pg_dump 17.11 plain file leaves on the session")
    func preserveCoversPgDumpPrologue() {
        let pgDumpSets = [
            "statement_timeout", "lock_timeout", "idle_in_transaction_session_timeout", "transaction_timeout",
            "client_encoding", "standard_conforming_strings", "search_path", "check_function_bodies", "xmloption",
            "client_min_messages", "row_security", "default_tablespace", "default_table_access_method"
        ]
        let preserved = Set(PostgreSQLSessionScopeSQL.preservedNames.map { $0.lowercased() })
        for name in pgDumpSets {
            #expect(preserved.contains(name), "\(name)")
        }
    }

    @Test("Preserve also covers the settings a value's text depends on and the foreign key switch")
    func preserveCoversTextAndReplicationRole() {
        let preserved = Set(PostgreSQLSessionScopeSQL.preservedNames.map { $0.lowercased() })
        for name in ["datestyle", "intervalstyle", "extra_float_digits", "timezone", "session_replication_role"] {
            #expect(preserved.contains(name), "\(name)")
        }
    }

    @Test("The read scope sets what pg_dump's reading session sets")
    func verbatimReadMatchesPgDump() {
        #expect(PostgreSQLSessionScopeSQL.verbatimReadSettings == [
            Self.setting("DateStyle", "ISO"),
            Self.setting("IntervalStyle", "postgres"),
            Self.setting("extra_float_digits", "3")
        ])
    }

    @Test("The capture matches names ignoring case, since pg_settings spells DateStyle and TimeZone in mixed case")
    func captureIgnoresCase() {
        let statement = PostgreSQLSessionScopeSQL.captureStatement(names: ["DateStyle", "search_path", "TimeZone"])
        #expect(statement.sql == """
            SELECT name, setting FROM pg_catalog.pg_settings \
            WHERE pg_catalog.lower(name) IN ('datestyle', 'search_path', 'timezone')
            """)
        #expect(statement.parameters.isEmpty)
    }

    @Test("Captured settings come back in the order asked and spelled as asked, whatever the server sent")
    func settingsFollowTheAskedNames() {
        let rows: [[String?]] = [["TimeZone", "UTC"], ["unrelated", "x"], ["DateStyle", "SQL, DMY"]]
        let settings = PostgreSQLSessionScopeSQL.settings(
            fromRows: rows,
            names: ["datestyle", "intervalstyle", "timezone"]
        )
        #expect(settings == [Self.setting("datestyle", "SQL, DMY"), Self.setting("timezone", "UTC")])
    }

    @Test("A reported NULL is kept as a nil value, not dropped")
    func reportedNullIsKept() {
        let settings = PostgreSQLSessionScopeSQL.settings(fromRows: [["search_path", nil]], names: ["search_path"])
        #expect(settings == [Self.setting("search_path", nil)])
    }

    @Test("A read scope applies only when the server has every one of its settings")
    func readScopeNeedsEverySetting() {
        let names = PostgreSQLSessionScopeSQL.verbatimReadNames
        let all = [Self.setting("DateStyle", "ISO, MDY"), Self.setting("IntervalStyle", "postgres"),
                   Self.setting("extra_float_digits", "1")]
        #expect(PostgreSQLSessionScopeSQL.completeSettings(all, names: names) == all)
        #expect(PostgreSQLSessionScopeSQL.completeSettings(Array(all.prefix(2)), names: names) == nil)
    }

    @Test("Every setting goes in one statement, its names and values bound rather than written into the text")
    func setStatementBindsEverything() throws {
        let statement = try #require(PostgreSQLSessionScopeSQL.setStatement([
            Self.setting("search_path", "\"$user\", public"),
            Self.setting("default_tablespace", "")
        ]))
        #expect(statement.sql == "SELECT pg_catalog.set_config($1, $2, false), pg_catalog.set_config($3, $4, false)")
        #expect(statement.parameters == [
            .text("search_path"), .text("\"$user\", public"), .text("default_tablespace"), .text("")
        ])
    }

    @Test("A quote or backslash in a value never reaches the statement text")
    func hostileValueStaysBound() throws {
        let value = #"it's \'; RESET ALL; --"#
        let statement = try #require(PostgreSQLSessionScopeSQL.setStatement([Self.setting("search_path", value)]))
        #expect(statement.sql == "SELECT pg_catalog.set_config($1, $2, false)")
        #expect(statement.parameters == [.text("search_path"), .text(value)])
    }

    @Test("A nil value binds SQL NULL, which set_config takes as a reset")
    func nilValueBindsNull() throws {
        let statement = try #require(PostgreSQLSessionScopeSQL.setStatement([Self.setting("extra_float_digits", nil)]))
        #expect(statement.parameters == [.text("extra_float_digits"), .null])
    }

    @Test("No settings, no statement")
    func emptySetIsNil() {
        #expect(PostgreSQLSessionScopeSQL.setStatement([]) == nil)
    }

    @Test("The applied values are what set_config returned, falling back to what was asked")
    func appliedValuesComeFromTheServer() {
        let applied = PostgreSQLSessionScopeSQL.appliedSettings(
            PostgreSQLSessionScopeSQL.verbatimReadSettings,
            reportedRow: ["ISO, DMY", "postgres"]
        )
        #expect(applied == [
            Self.setting("DateStyle", "ISO, DMY"),
            Self.setting("IntervalStyle", "postgres"),
            Self.setting("extra_float_digits", "3")
        ])
    }

    @Test("Only saved settings the session no longer holds are restored")
    func onlyChangedSettingsRestore() {
        let saved = [
            Self.setting("search_path", "\"$user\", public"),
            Self.setting("session_replication_role", "origin"),
            Self.setting("statement_timeout", "30000"),
            Self.setting("default_tablespace", "")
        ]
        let current = [
            Self.setting("search_path", ""),
            Self.setting("session_replication_role", "origin"),
            Self.setting("statement_timeout", "0"),
            Self.setting("default_tablespace", "")
        ]
        #expect(PostgreSQLSessionScopeSQL.changedSettings(saved: saved, current: current) == [
            Self.setting("search_path", "\"$user\", public"),
            Self.setting("statement_timeout", "30000")
        ])
    }

    @Test("Names compare ignoring case, and a setting the re-read did not report is left alone")
    func changedSettingsMatchNamesAndSkipMissing() {
        let saved = [Self.setting("DateStyle", "SQL, DMY"), Self.setting("transaction_timeout", "0")]
        let current = [Self.setting("datestyle", "ISO, DMY")]
        #expect(PostgreSQLSessionScopeSQL.changedSettings(saved: saved, current: current) == [
            Self.setting("DateStyle", "SQL, DMY")
        ])
    }

    @Test("Nothing is restored inside an aborted transaction")
    func noRestoreInAbortedTransaction() {
        #expect(!PostgreSQLSessionScopeSQL.canRestore(in: .abortedTransaction))
    }

    @Test("A restore runs with no transaction, inside an open one, or when the state is not known")
    func restoreRunsOtherwise() {
        #expect(PostgreSQLSessionScopeSQL.canRestore(in: .idle))
        #expect(PostgreSQLSessionScopeSQL.canRestore(in: .inTransaction))
        #expect(PostgreSQLSessionScopeSQL.canRestore(in: .unknown))
    }

    @Test("A read scope opens on an idle session")
    func readScopeOpensWhenIdle() {
        #expect(PostgreSQLSessionScopeSQL.canOpenReadScope(in: .idle))
    }

    /// Measured on PostgreSQL 17.11: after `SET LOCAL extra_float_digits = 0` in a transaction, a capture reads 0,
    /// and a session-level set to 3 then back to 0 leaves 0 after `COMMIT` in place of the session's 1.
    @Test(
        "A read scope does not open inside a transaction, open or aborted, or when the state is not known",
        arguments: [PluginSessionTransactionState.inTransaction, .abortedTransaction, .unknown, .holdsSessionLocks]
    )
    func readScopeRefusesOtherwise(state: PluginSessionTransactionState) {
        #expect(!PostgreSQLSessionScopeSQL.canOpenReadScope(in: state))
    }

    private static func unconnectedDriver() -> PostgreSQLPluginDriver {
        PostgreSQLPluginDriver(config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: ""))
    }

    /// Measured on PostgreSQL 17.11 and 18.6: for a role without the privilege the block answers DO and the
    /// transaction keeps its rows, where the bare `SET` aborts it.
    @Test("The foreign key switch swallows a refused SET, both ways")
    func foreignKeySwitchSwallowsRefusal() {
        let driver = Self.unconnectedDriver()
        #expect(driver.foreignKeyDisableStatements() == [
            "DO $$ BEGIN SET session_replication_role = replica; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$",
        ])
        #expect(driver.foreignKeyEnableStatements() == [
            "DO $$ BEGIN SET session_replication_role = DEFAULT; EXCEPTION WHEN insufficient_privilege THEN NULL; END $$",
        ])
    }

    @Test("Relaxing foreign keys opens no scope, since replica would also stop the target's user triggers")
    func relaxedForeignKeysOpensNoScope() async throws {
        #expect(try await Self.unconnectedDriver().openSessionScope(for: .relaxedForeignKeys) == nil)
    }
}
