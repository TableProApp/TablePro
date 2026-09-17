//
//  SQLExportHarness.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

@testable import TablePro

/// Runs a real SQL export and hands back the dump it wrote.
///
/// `SQLExportPlugin.settings` has a `didSet` that writes to the app's own `UserDefaults`, so the
/// capture, reset and restore around an export is a read-modify-write over state every suite
/// shares. Swift Testing runs suites in parallel, so two of them doing that by hand interleave:
/// one restores what the other captured, and the developer's real export settings are left at
/// whatever the loser wrote. A leaked gzip flag also makes the dump unreadable as text, which
/// reads as a flaky assertion rather than as the cross-suite write it is.
///
/// One actor owns that window, so every export harness in the target queues behind it.
internal actor SQLExportHarness {
    internal static let shared = SQLExportHarness()

    /// `progress` is injectable so a suite can cancel the export from inside its own data source and
    /// assert what a stopped run leaves behind.
    internal func dump(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        options: SQLExportOptions = SQLExportOptions(),
        progress: PluginExportProgress? = nil
    ) async throws -> (text: String, result: ExportFormatResult) {
        let plugin = SQLExportPlugin()
        let storedSettings = plugin.settings
        plugin.settings = options
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sql")
        defer {
            plugin.settings = storedSettings
            try? FileManager.default.removeItem(at: destination)
        }

        let result = try await plugin.export(
            tables: tables,
            dataSource: dataSource,
            destination: destination,
            progress: progress ?? PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return (try String(contentsOf: destination, encoding: .utf8), result)
    }

    /// The parts a split export wrote, in restore order, and the whole dump as one part when it did
    /// not split. A split export never writes the name the user chose, so reading that path back
    /// finds nothing at all.
    internal func dumpParts(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        options: SQLExportOptions = SQLExportOptions(),
        progress: PluginExportProgress? = nil
    ) async throws -> (parts: [String], result: ExportFormatResult) {
        let plugin = SQLExportPlugin()
        let storedSettings = plugin.settings
        plugin.settings = options
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sql")
        var written = [destination]
        defer {
            plugin.settings = storedSettings
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let result = try await plugin.export(
            tables: tables,
            dataSource: dataSource,
            destination: destination,
            progress: progress ?? PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )

        var parts: [String] = []
        var index = 1
        while true {
            let part = SQLExportFileWriter.partURL(for: destination, part: index)
            guard FileManager.default.fileExists(atPath: part.path(percentEncoded: false)) else { break }
            written.append(part)
            parts.append(try String(contentsOf: part, encoding: .utf8))
            index += 1
        }
        guard parts.isEmpty else { return (parts, result) }
        return ([try String(contentsOf: destination, encoding: .utf8)], result)
    }
}
