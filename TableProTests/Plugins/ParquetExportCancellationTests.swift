//
//  ParquetExportCancellationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct ParquetExportCancellationTests {
    @Test("Stopping between tables removes the files already written")
    func stopBetweenTablesRemovesWrittenFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("dump.parquet")
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 0))
        var attempted: [String] = []

        await #expect(throws: PluginExportCancellationError.self) {
            try await ParquetTableFiles.write(
                [table("users"), table("orders")], destination: destination, progress: progress
            ) { table, fileURL in
                attempted.append(table.name)
                try Data("PAR1".utf8).write(to: fileURL)
                progress.cancel()
            }
        }

        #expect(attempted == ["users"])
        #expect(!fileExists(for: "users", destination: destination))
        #expect(!fileExists(for: "orders", destination: destination))
    }

    @Test("A table that fails to write removes the files already written")
    func failedTableRemovesWrittenFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("dump.parquet")
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 0))

        await #expect(throws: PluginExportError.self) {
            try await ParquetTableFiles.write(
                [table("users"), table("orders")], destination: destination, progress: progress
            ) { table, fileURL in
                guard table.name == "users" else { throw PluginExportError.exportFailed("orders") }
                try Data("PAR1".utf8).write(to: fileURL)
            }
        }

        #expect(!fileExists(for: "users", destination: destination))
    }

    @Test("A finished multi-table export keeps one file per table")
    func finishedExportKeepsEveryFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("dump.parquet")
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 0))

        try await ParquetTableFiles.write(
            [table("users"), table("orders")], destination: destination, progress: progress
        ) { _, fileURL in
            try Data("PAR1".utf8).write(to: fileURL)
        }

        #expect(fileExists(for: "users", destination: destination))
        #expect(fileExists(for: "orders", destination: destination))
    }

    @Test("A single table is written to the destination itself")
    func singleTableWritesToDestination() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("dump.parquet")
        let progress = PluginExportProgress(progress: Progress(totalUnitCount: 0))
        var targets: [URL] = []

        try await ParquetTableFiles.write(
            [table("users")], destination: destination, progress: progress
        ) { _, fileURL in
            targets.append(fileURL)
        }

        #expect(targets == [destination])
    }

    private func table(_ name: String) -> PluginExportTable {
        PluginExportTable(name: name, databaseName: "main", tableType: "table")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parquet-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileExists(for table: String, destination: URL) -> Bool {
        let url = ParquetFileNaming.perTableURL(destination: destination, table: table)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
