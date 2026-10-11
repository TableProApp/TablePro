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
            #expect(message.contains("overwritten"), "\(type.rawValue)")
        }
        for type in [DatabaseType.postgresql, .redshift, .mongodb, .sqlite, .libsql, .mssql, .duckdb] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(!message.contains("overwritten"), "\(type.rawValue)")
        }
    }

    @Test("pg_restore, mongorestore and sqlite3 say existing objects are kept and added to")
    func appendingEnginesKeepExistingObjects() throws {
        for type in [DatabaseType.postgresql, .redshift, .mongodb, .sqlite, .libsql] {
            let message = try #require(RestoreConfirmationText.message(for: type))
            #expect(message.contains("kept"), "\(type.rawValue)")
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
