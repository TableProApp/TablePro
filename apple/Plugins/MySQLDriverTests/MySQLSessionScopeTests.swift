//
//  MySQLSessionScopeTests.swift
//  TableProTests
//

import Foundation
import TableProMySQLCore
import TableProPluginKit
import Testing

struct MySQLSessionScopeTests {
    @Test("Preserving saves what a mysqldump or mariadb-dump file changes, autocommit last, and sets nothing")
    func preserveSavesTheDumpSettings() {
        #expect(MySQLSessionScopePlan.savedNames(for: .preserve) == [
            "sql_mode", "time_zone", "character_set_client", "character_set_results",
            "collation_connection", "foreign_key_checks", "unique_checks", "sql_notes", "note_verbosity", "autocommit",
        ])
        #expect(MySQLSessionScopePlan.applied(for: .preserve, saved: []) == [])
    }

    private static let beforeImport = MySQLSessionScopePlan.captured(rows: [
        ["autocommit", "ON"], ["foreign_key_checks", "ON"], ["sql_mode", "STRICT_TRANS_TABLES"], ["sql_notes", "ON"],
    ], names: MySQLSessionScopePlan.preservedNames)

    private static let leftByStoppedFile = MySQLSessionScopePlan.captured(rows: [
        ["autocommit", "OFF"], ["foreign_key_checks", "OFF"], ["sql_mode", "NO_AUTO_VALUE_ON_ZERO"], ["sql_notes", "OFF"],
    ], names: MySQLSessionScopePlan.preservedNames)

    /// `SET autocommit = 1` commits what the session holds open, so it goes after every other restore.
    @Test("With no transaction open, closing a preserve scope restores autocommit after everything else")
    func autocommitIsRestoredLast() {
        let restore = MySQLSessionScopePlan.restore(
            saved: Self.beforeImport, current: Self.leftByStoppedFile, isTransactionOpen: false
        )
        #expect(restore.statements == [
            "SET SESSION sql_mode = 'STRICT_TRANS_TABLES'",
            "SET SESSION foreign_key_checks = 'ON'",
            "SET SESSION sql_notes = 'ON'",
            "SET SESSION autocommit = 'ON'",
        ])
        #expect(restore.isComplete)
    }

    /// The open transaction may be the user's, begun in the editor before the import, and `SET autocommit = 1` would
    /// commit it along with whatever the file left pending.
    @Test("With a transaction open, autocommit stays as the file left it and the restore reports itself incomplete")
    func autocommitWaitsForOpenTransaction() {
        let restore = MySQLSessionScopePlan.restore(
            saved: Self.beforeImport, current: Self.leftByStoppedFile, isTransactionOpen: true
        )
        #expect(restore.statements == [
            "SET SESSION sql_mode = 'STRICT_TRANS_TABLES'",
            "SET SESSION foreign_key_checks = 'ON'",
            "SET SESSION sql_notes = 'ON'",
        ])
        #expect(!restore.isComplete)
    }

    @Test("An open transaction holds nothing back when autocommit never changed")
    func unchangedAutocommitIsComplete() {
        let restore = MySQLSessionScopePlan.restore(
            saved: Self.beforeImport, current: Self.beforeImport, isTransactionOpen: true
        )
        #expect(restore.statements.isEmpty)
        #expect(restore.isComplete)
    }

    @Test("Reading runs as mysqldump's own connection does, and writing derives its mode from the session's")
    func verbatimPurposesPinModeAndZone() {
        let saved = [
            PluginSessionSetting(name: "sql_mode", value: "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_DATE"),
            PluginSessionSetting(name: "time_zone", value: "SYSTEM"),
        ]
        #expect(MySQLSessionScopePlan.savedNames(for: .verbatimRead) == ["sql_mode", "time_zone"])
        #expect(MySQLSessionScopePlan.savedNames(for: .verbatimWrite) == ["sql_mode", "time_zone"])
        #expect(MySQLSessionScopePlan.applied(for: .verbatimRead, saved: saved) == [
            PluginSessionSetting(name: "sql_mode", value: ""),
            PluginSessionSetting(name: "time_zone", value: "+00:00"),
        ])
        #expect(MySQLSessionScopePlan.applied(for: .verbatimWrite, saved: saved) == [
            PluginSessionSetting(name: "sql_mode", value: "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_AUTO_VALUE_ON_ZERO"),
            PluginSessionSetting(name: "time_zone", value: "+00:00"),
        ])
    }

    /// A copy accepts what the user's session accepts plus zero dates and AUTO_INCREMENT 0. The TRADITIONAL rows are
    /// what MySQL 8.4.11 and MariaDB 13.0.2 report for `SET sql_mode = 'TRADITIONAL'`.
    @Test("The write mode drops only the zero-date flags and TRADITIONAL, and adds NO_AUTO_VALUE_ON_ZERO", arguments: [
        ("ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION",
         "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO"),
        ("STRICT_ALL_TABLES,NO_ZERO_DATE", "STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO"),
        ("STRICT_TRANS_TABLES,ALLOW_INVALID_DATES", "STRICT_TRANS_TABLES,ALLOW_INVALID_DATES,NO_AUTO_VALUE_ON_ZERO"),
        ("", "NO_AUTO_VALUE_ON_ZERO"),
        ("NO_ENGINE_SUBSTITUTION", "NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO"),
        ("STRICT_TRANS_TABLES,STRICT_ALL_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,TRADITIONAL,NO_ENGINE_SUBSTITUTION",
         "STRICT_TRANS_TABLES,STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO"),
        ("STRICT_TRANS_TABLES,STRICT_ALL_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,TRADITIONAL,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION",
         "STRICT_TRANS_TABLES,STRICT_ALL_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION,NO_AUTO_VALUE_ON_ZERO"),
        ("ANSI_QUOTES,NO_BACKSLASH_ESCAPES", "ANSI_QUOTES,NO_BACKSLASH_ESCAPES,NO_AUTO_VALUE_ON_ZERO"),
        ("REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,ANSI",
         "REAL_AS_FLOAT,PIPES_AS_CONCAT,ANSI_QUOTES,IGNORE_SPACE,ONLY_FULL_GROUP_BY,ANSI,NO_AUTO_VALUE_ON_ZERO"),
        ("NO_AUTO_VALUE_ON_ZERO,STRICT_TRANS_TABLES", "NO_AUTO_VALUE_ON_ZERO,STRICT_TRANS_TABLES"),
    ])
    func writeModeFollowsTheSession(_ sessionMode: String, _ writeMode: String) {
        let saved = [PluginSessionSetting(name: "sql_mode", value: sessionMode)]
        #expect(MySQLSessionScopePlan.writeMode(saved: saved) == writeMode)
    }

    /// `SET SESSION foreign_key_checks = 'OFF'` and `'ON'` measured on MySQL 8.4.13, inside a transaction too.
    @Test("Relaxing foreign keys saves foreign_key_checks alone, turns it off, and closing turns it back on")
    func relaxedForeignKeysPlan() {
        let saved = [PluginSessionSetting(name: "foreign_key_checks", value: "ON")]
        #expect(MySQLSessionScopePlan.savedNames(for: .relaxedForeignKeys) == ["foreign_key_checks"])
        let applied = MySQLSessionScopePlan.applied(for: .relaxedForeignKeys, saved: saved)
        #expect(applied == [PluginSessionSetting(name: "foreign_key_checks", value: "OFF")])
        #expect(applied?.compactMap { MySQLSessionStatements.assignment(name: $0.name, value: $0.value) } == [
            "SET SESSION foreign_key_checks = 'OFF'",
        ])
        let restore = MySQLSessionScopePlan.restore(saved: saved, current: applied ?? [], isTransactionOpen: true)
        #expect(restore.statements == ["SET SESSION foreign_key_checks = 'ON'"])
        #expect(restore.isComplete)
    }

    @Test("A write scope with no saved mode adds only NO_AUTO_VALUE_ON_ZERO, and reading ignores the session's mode")
    func writeModeWithoutSavedMode() {
        #expect(MySQLSessionScopePlan.writeMode(saved: []) == "NO_AUTO_VALUE_ON_ZERO")
        let saved = [PluginSessionSetting(name: "sql_mode", value: "ANSI_QUOTES,NO_BACKSLASH_ESCAPES")]
        #expect(MySQLSessionScopePlan.applied(for: .verbatimRead, saved: saved)?.first?.value == "")
    }

    @Test("Captured settings follow the names asked, read an empty character set as NULL and keep ON and OFF")
    func capturedSettings() {
        let rows: [[PluginCellValue]] = [
            ["UNIQUE_CHECKS", "ON"],
            ["sql_mode", ""],
            ["character_set_results", ""],
            ["foreign_key_checks", "OFF"],
            ["time_zone", "SYSTEM"],
        ]
        let captured = MySQLSessionScopePlan.captured(rows: rows, names: MySQLSessionScopePlan.preservedNames)
        #expect(captured == [
            PluginSessionSetting(name: "sql_mode", value: ""),
            PluginSessionSetting(name: "time_zone", value: "SYSTEM"),
            PluginSessionSetting(name: "character_set_results", value: nil),
            PluginSessionSetting(name: "foreign_key_checks", value: "OFF"),
            PluginSessionSetting(name: "unique_checks", value: "ON"),
        ])
    }

    @Test("Closing puts back only what changed, spelling NULL and ON or OFF the way SET takes them")
    func restoresOnlyWhatChanged() {
        let saved = [
            PluginSessionSetting(name: "sql_mode", value: "STRICT_TRANS_TABLES"),
            PluginSessionSetting(name: "time_zone", value: "SYSTEM"),
            PluginSessionSetting(name: "character_set_results", value: nil),
            PluginSessionSetting(name: "foreign_key_checks", value: "ON"),
        ]
        let current = [
            PluginSessionSetting(name: "sql_mode", value: "NO_AUTO_VALUE_ON_ZERO"),
            PluginSessionSetting(name: "time_zone", value: "SYSTEM"),
            PluginSessionSetting(name: "character_set_results", value: "utf8mb4"),
            PluginSessionSetting(name: "foreign_key_checks", value: "OFF"),
        ]
        #expect(MySQLSessionScopePlan.restore(saved: saved, current: current, isTransactionOpen: false).statements == [
            "SET SESSION sql_mode = 'STRICT_TRANS_TABLES'",
            "SET SESSION character_set_results = NULL",
            "SET SESSION foreign_key_checks = 'ON'",
        ])
        #expect(MySQLSessionScopePlan.restore(saved: saved, current: saved, isTransactionOpen: false).statements.isEmpty)
    }

    @Test("A saved setting the server no longer reports is still put back")
    func restoresUnreportedSetting() {
        let saved = [PluginSessionSetting(name: "unique_checks", value: "ON")]
        #expect(MySQLSessionScopePlan.restore(saved: saved, current: [], isTransactionOpen: false).statements == [
            "SET SESSION unique_checks = 'ON'",
        ])
    }

    @Test("A saved name that is not a setting name is never interpolated")
    func refusesForeignName() {
        let saved = [PluginSessionSetting(name: "sql_mode = ''; DROP TABLE t; --", value: "x")]
        #expect(MySQLSessionScopePlan.restore(saved: saved, current: [], isTransactionOpen: false).statements.isEmpty)
    }

    @Test("A held session scope blocks replay and the idle release until it closes")
    func heldScopeBlocksReplayAndRelease() {
        var footprint = MySQLSessionFootprint()
        footprint.holdSessionScope()
        #expect(!footprint.isClean)
        #expect(footprint.blockingReason != nil)
        #expect(!mysqlMayReplay("SELECT 1", on: footprint))

        footprint.releaseSessionScope(isRestored: true)
        #expect(footprint.isClean)
        #expect(footprint.blockingReason == nil)
        #expect(mysqlMayReplay("SELECT 1", on: footprint))
    }

    @Test("Every held scope has to close before the session is clean, and an extra close changes nothing")
    func nestedScopes() {
        var footprint = MySQLSessionFootprint()
        footprint.holdSessionScope()
        footprint.holdSessionScope()
        footprint.releaseSessionScope(isRestored: true)
        #expect(!footprint.isClean)

        footprint.releaseSessionScope(isRestored: true)
        footprint.releaseSessionScope(isRestored: true)
        #expect(footprint.isClean)
    }

    @Test("Settings a scope could not put back leave the session marked as changed")
    func unrestoredSettingsStayMarked() {
        var held = MySQLSessionFootprint()
        held.holdSessionScope()
        held.releaseSessionScope(isRestored: false)
        #expect(held.heldSessionScopes == 0)
        #expect(held.hasSessionSettings)
        #expect(held.blockingReason != nil)
        #expect(!mysqlMayReplay("SELECT 1", on: held))

        var preserved = MySQLSessionFootprint()
        preserved.noteUnrestoredSessionSettings()
        #expect(preserved.hasSessionSettings)
        #expect(!mysqlMayReplay("SELECT 1", on: preserved))
    }

    @Test("Databend opens no session scope and records no creation settings")
    func databendHasNoScopes() async throws {
        let driver = MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "",
            additionalFields: ["driverVariant": MySQLServerFlavor.databendVariant]
        ))
        for purpose in [PluginSessionPurpose.preserve, .verbatimRead, .verbatimWrite, .relaxedForeignKeys] {
            #expect(try await driver.openSessionScope(for: purpose) == nil)
        }
        let routine = PluginRoutineInfo(name: "cleanup", kind: .procedure)
        let trigger = PluginTriggerInfo(
            name: "audit", table: "orders", timing: "BEFORE", event: "INSERT", statement: "BEGIN END"
        )
        #expect(try await driver.fetchRoutineCreationScope(routine) == nil)
        #expect(try await driver.fetchTriggerCreationScope(trigger) == nil)
        #expect(try await driver.fetchEventCreationScope(PluginEventInfo(name: "nightly")) == nil)
    }

    @Test("A creation scope needs a recorded mode, and carries the zone only when there is one")
    func creationScopeNeedsRecordedMode() {
        #expect(MySQLPluginDriver.creationScope(sqlMode: nil, timeZone: "SYSTEM") == nil)
        let routine = MySQLPluginDriver.creationScope(sqlMode: "STRICT_TRANS_TABLES", timeZone: nil)
        #expect(routine?.opening == [
            "/*!50003 SET @saved_sql_mode = @@sql_mode */",
            "/*!50003 SET sql_mode = 'STRICT_TRANS_TABLES' */",
        ])
        #expect(routine?.closing == ["/*!50003 SET sql_mode = @saved_sql_mode */"])
        let event = MySQLPluginDriver.creationScope(sqlMode: "", timeZone: "SYSTEM")
        #expect(event?.opening.count == 4)
        #expect(event?.closing.first == "/*!50003 SET time_zone = @saved_time_zone */")
        let mariaDBRoutine = MySQLPluginDriver.creationScope(
            sqlMode: "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION",
            timeZone: nil
        )
        #expect(mariaDBRoutine?.opening.last
            == "/*!50003 SET sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION' */")
    }
}
