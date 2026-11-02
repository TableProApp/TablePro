//
//  RestoreConfirmationTextTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct RestoreConfirmationTextTests {
    @Test("Only MySQL and MariaDB, whose dump drops and recreates each table, say objects are overwritten")
    func onlyMySQLOverwrites() throws {
        for type in [DatabaseType.mysql, .mariadb] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(message.contains("overwrites each object"), "\(type.rawValue)")
        }
        for type in [DatabaseType.postgresql, .redshift, .mongodb, .sqlite, .libsql, .mssql, .duckdb] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(!message.contains("overwrit"), "\(type.rawValue)")
        }
    }

    @Test("mysql runs without --force, so MySQL and MariaDB say the restore stops at the first error and keeps what ran")
    func mySQLStopsAtTheFirstError() throws {
        for type in [DatabaseType.mysql, .mariadb] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(message.contains("stops at the first error and keeps what ran before it"), "\(type.rawValue)")
        }
    }

    @Test("pg_restore and mongorestore say existing objects are kept, added to, and errors do not stop the run")
    func appendingEnginesKeepExistingObjects() throws {
        for type in [DatabaseType.postgresql, .redshift, .mongodb] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(message.contains("kept, not replaced"), "\(type.rawValue)")
            #expect(message.contains("carries on past errors"), "\(type.rawValue)")
        }
    }

    @Test("sqlite3 runs with -bail, so SQLite and libSQL say the restore stops at the first error and keeps no transaction")
    func sqliteStopsAtTheFirstError() throws {
        for type in [DatabaseType.sqlite, .libsql] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(message.contains("stops at the first error"), "\(type.rawValue)")
            #expect(message.contains("none of it is kept"), "\(type.rawValue)")
            #expect(message.contains("what ran before the error stays"), "\(type.rawValue)")
            #expect(!message.contains("added to them"), "\(type.rawValue)")
        }
    }

    @Test("DuckDB says the restore stops at an object that already exists, in both formats")
    func duckDBStopsAtExistingObjects() throws {
        for format in NativeDumpRegistry.formats(for: .duckdb) {
            let message = try #require(RestoreConfirmationText.message(for: .duckdb, formatId: format.id))
            #expect(message.contains("stops"), "\(format.id)")
        }
    }

    @Test("SQL Server says the import needs an empty database")
    func sqlServerNeedsAnEmptyDatabase() throws {
        let message = try #require(RestoreConfirmationText.message(for: .mssql))
        #expect(message.contains("empty database"))
    }

    @Test("Every message says the change cannot be undone")
    func everyMessageWarnsItCannotBeUndone() throws {
        for type in [DatabaseType.mysql, .postgresql, .mongodb, .sqlite, .mssql, .duckdb] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(message.contains("cannot be undone"), "\(type.rawValue)")
        }
    }

    @Test("An engine with no dump has no confirmation to show")
    func unsupportedEngineHasNoMessage() {
        #expect(RestoreConfirmationText.message(for: .clickhouse) == nil)
    }
}
