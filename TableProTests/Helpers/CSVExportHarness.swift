//
//  CSVExportHarness.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

@testable import TablePro

/// Runs a real CSV export and hands back the bytes it wrote.
///
/// Bytes rather than a decoded string, because what this suite is about is which bytes reached the
/// file: a decode would put the encoding back and hide the answer.
///
/// `CSVExportPlugin.settings` has a `didSet` that writes to the app's own `UserDefaults`, so the
/// capture, reset and restore around an export is a read-modify-write over state every suite
/// shares. Actor isolation alone does not protect it: an actor is reentrant across a suspension,
/// so a second call entering at the `await` reads the first call's test options as the value to
/// restore, and the developer's real export settings are left at whatever a test chose. Each run
/// therefore waits on the one before it.
internal actor CSVExportHarness {
    internal static let shared = CSVExportHarness()

    private var pending: Task<Void, Never>?

    internal func bytes(
        options: CSVExportOptions,
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource
    ) async throws -> (data: Data, result: ExportFormatResult) {
        let predecessor = pending
        let work = Task { () async -> Result<(data: Data, result: ExportFormatResult), Error> in
            await predecessor?.value
            do {
                return .success(try await Self.run(options: options, tables: tables, dataSource: dataSource))
            } catch {
                return .failure(error)
            }
        }
        pending = Task { _ = await work.value }
        return try await work.value.get()
    }

    private static func run(
        options: CSVExportOptions,
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource
    ) async throws -> (data: Data, result: ExportFormatResult) {
        let plugin = CSVExportPlugin()
        let storedSettings = plugin.settings
        plugin.settings = options
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).csv")
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
        return (try Data(contentsOf: destination), result)
    }
}
