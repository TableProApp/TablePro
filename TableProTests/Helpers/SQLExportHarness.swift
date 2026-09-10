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

    internal func dump(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource
    ) async throws -> (text: String, result: ExportFormatResult) {
        let plugin = SQLExportPlugin()
        let storedSettings = plugin.settings
        plugin.settings = SQLExportOptions()
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
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
        )
        return (try String(contentsOf: destination, encoding: .utf8), result)
    }
}
