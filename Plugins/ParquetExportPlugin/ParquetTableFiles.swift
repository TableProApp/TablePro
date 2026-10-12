//
//  ParquetTableFiles.swift
//  ParquetExportPlugin
//

import Foundation
import TableProPluginKit

public enum ParquetTableFiles {
    public static func write(
        _ tables: [PluginExportTable],
        destination: URL,
        progress: PluginExportProgress,
        writeTable: (PluginExportTable, URL) async throws -> Void
    ) async throws {
        var written: [URL] = []
        do {
            for (index, table) in tables.enumerated() {
                try progress.checkCancellation()
                progress.setCurrentTable(table.qualifiedName, index: index + 1)
                let fileURL = fileURL(for: table, tableCount: tables.count, destination: destination)
                try await writeTable(table, fileURL)
                written.append(fileURL)
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private static func fileURL(for table: PluginExportTable, tableCount: Int, destination: URL) -> URL {
        guard tableCount > 1 else { return destination }
        return ParquetFileNaming.perTableURL(destination: destination, table: table.name)
    }
}
