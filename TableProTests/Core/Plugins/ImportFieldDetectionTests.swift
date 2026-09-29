//
//  ImportFieldDetectionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class BlockingDetectionPlugin: ImportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Blocking Detection"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Detects fields until it is cancelled"
    static let formatId = "blocking-detection"
    static let formatDisplayName = "Blocking"
    static let acceptedFileExtensions = ["blocking"]
    static let iconName = "doc"

    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    required init() {}

    var hasStarted: Bool { lock.withLock { started } }
    var sawCancellation: Bool { lock.withLock { cancelled } }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        PluginImportResult(executedStatements: 0, executionTime: 0)
    }

    func detectSourceFields(at url: URL, targetTable: String?) throws -> [PluginImportField] {
        lock.withLock { started = true }
        let deadline = Date().addingTimeInterval(10)
        while !Task.isCancelled, Date() < deadline {
            usleep(1_000)
        }
        guard Task.isCancelled else { return [] }
        lock.withLock { cancelled = true }
        throw CancellationError()
    }
}

struct ImportFieldDetectionTests {
    /// The import sheet reads the file from a detached task. Nothing cancelled that task, so closing
    /// the sheet left a whole-file read running to the end.
    @Test("Cancelling the caller cancels a detection already reading the file")
    func cancellingTheCallerStopsTheRead() async throws {
        let plugin = BlockingDetectionPlugin()
        let caller = Task {
            try await ImportFieldDetection.detectFields(
                plugin: plugin,
                at: URL(fileURLWithPath: "/dev/null"),
                targetTable: nil
            )
        }
        for _ in 0..<500 where !plugin.hasStarted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(plugin.hasStarted)

        caller.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await caller.value
        }
        #expect(plugin.sawCancellation)
    }
}
