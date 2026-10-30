//
//  NativeDumpParquetRestoreTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

@MainActor
struct DuckDBParquetRestoreRefusalTests {
    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Local",
            host: "",
            port: 0,
            database: "",
            username: "",
            type: .duckdb,
            sshConfig: SSHConfiguration(),
            sslConfig: SSLConfiguration()
        )
    }

    @Test("Restore offers only the .duckdb file, so the open panel takes no folder")
    func restoreFormatsLeaveOutTheFolder() {
        let restorable = NativeDumpRegistry.restoreFormats(for: .duckdb)
        #expect(restorable.map(\.id) == ["duckdb"])
        #expect(!restorable.contains { $0.producesDirectory })
    }

    @Test("Backup still offers the Parquet folder")
    func backupKeepsTheFolder() {
        #expect(NativeDumpRegistry.formats(for: .duckdb).map(\.id) == ["duckdb", "parquet"])
    }

    @Test("Every other engine restores each format it backs up")
    func otherEnginesRestoreEveryFormat() {
        for type in [DatabaseType.postgresql, .redshift, .mysql, .mariadb, .mongodb, .sqlite, .libsql, .mssql] {
            #expect(NativeDumpRegistry.restoreFormats(for: type) == NativeDumpRegistry.formats(for: type))
        }
    }

    @Test("A Parquet folder restore is refused before anything runs")
    func serviceRefusesParquetRestore() async {
        let service = NativeDumpService(kind: .restore)
        await #expect(throws: NativeDumpError.formatCannotRestore) {
            try await service.start(
                connection: connection(),
                database: "live",
                fileURL: URL(fileURLWithPath: "/tmp/export", isDirectory: true),
                formatId: "parquet"
            )
        }
        #expect(service.state == .idle)
    }

    @Test("A Parquet folder backup is not refused")
    func serviceDoesNotRefuseParquetBackup() async {
        let service = NativeDumpService(kind: .backup)
        await #expect(throws: NativeDumpError.noSession) {
            try await service.start(
                connection: connection(),
                database: "live",
                fileURL: URL(fileURLWithPath: "/tmp/export", isDirectory: true),
                formatId: "parquet"
            )
        }
    }

    @Test("A .duckdb file restore is not refused")
    func serviceDoesNotRefuseFileRestore() async {
        let service = NativeDumpService(kind: .restore)
        await #expect(throws: NativeDumpError.noSession) {
            try await service.start(
                connection: connection(),
                database: "live",
                fileURL: URL(fileURLWithPath: "/tmp/backup.duckdb"),
                formatId: "duckdb"
            )
        }
    }

    @Test("The refusal names the .duckdb format as the way to restore")
    func refusalNamesTheFileFormat() {
        #expect(NativeDumpError.formatCannotRestore.localizedDescription.contains(".duckdb"))
    }
}
