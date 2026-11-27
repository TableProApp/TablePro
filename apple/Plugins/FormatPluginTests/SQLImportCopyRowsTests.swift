//
//  SQLImportCopyRowsTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

private struct CopyRefusal: Error {}

private final class CopySink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    private let lock = NSLock()
    private var log: [String] = []
    private var received = Data()
    var refusesCopy = false
    var onPiece: @Sendable () -> Void = {}

    var calls: [String] { lock.withLock { log } }
    var copied: Data { lock.withLock { received } }

    func execute(statement: String) async throws {
        lock.withLock { log.append(statement) }
    }

    func copyFromStandardInput(statement: String, line: Int, rows: PluginCopyData) async throws {
        lock.withLock { log.append("\(statement) @\(line)") }
        if refusesCopy { throw CopyRefusal() }
        while let piece = try rows.nextPiece() {
            lock.withLock { received.append(piece) }
            onPiece()
        }
    }

    func deleteAllRowsFromTargetTable() async throws {}
    func beginTransaction() async throws { lock.withLock { log.append("BEGIN") } }
    func commitTransaction() async throws { lock.withLock { log.append("COMMIT") } }
    func rollbackTransaction() async throws { lock.withLock { log.append("ROLLBACK") } }
}

private final class ElementSource: PluginImportSource, @unchecked Sendable {
    private let elements: [PluginImportElement]

    init(_ elements: [PluginImportElement]) {
        self.elements = elements
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func elements() async throws -> AsyncThrowingStream<PluginImportElement, Error> {
        let elements = self.elements
        return AsyncThrowingStream { continuation in
            elements.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func fileURL() -> URL { URL(fileURLWithPath: "/dev/null") }
    func fileSizeBytes() -> Int64 { 0 }
}

private final class PieceList: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [Data]

    init(_ pieces: [String]) {
        self.pieces = pieces.map { Data($0.utf8) }
    }

    var data: PluginCopyData {
        PluginCopyData { [self] in
            lock.withLock { pieces.isEmpty ? nil : pieces.removeFirst() }
        }
    }
}

@Suite("SQL import COPY rows", .serialized)
struct SQLImportCopyRowsTests {
    private func runImport(
        _ elements: [PluginImportElement],
        sink: CopySink,
        errorHandling: ImportErrorHandling = .stopAndRollback,
        progress: PluginImportProgress = PluginImportProgress(progress: Progress())
    ) async -> Result<PluginImportResult, any Error> {
        let plugin = SQLImportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings.errorHandling = errorHandling
        plugin.settings.wrapInTransaction = true
        plugin.settings.disableForeignKeyChecks = false
        do {
            return .success(try await plugin.performImport(source: ElementSource(elements), sink: sink, progress: progress))
        } catch {
            return .failure(error)
        }
    }

    @Test("A COPY element goes to the sink with its rows, inside the import's transaction, counted as one statement")
    func copyRunsInsideTheTransaction() async throws {
        let sink = CopySink()
        let result = try await runImport([
            .statement("CREATE TABLE t (a int)", lineNumber: 1),
            .copyFromStandardInput(statement: "COPY t (a) FROM stdin", lineNumber: 2, rows: PieceList(["1\n2\n", "3\n"]).data),
            .statement("SELECT 1", lineNumber: 6),
        ], sink: sink).get()

        #expect(sink.calls == ["BEGIN", "CREATE TABLE t (a int)", "COPY t (a) FROM stdin @2", "SELECT 1", "COMMIT"])
        #expect(sink.copied == Data("1\n2\n3\n".utf8))
        #expect(result.executedStatements == 3)
    }

    @Test("A COPY the sink refuses fails the import at its line and rolls back")
    func refusedCopyStopsTheImport() async throws {
        let sink = CopySink()
        sink.refusesCopy = true
        let outcome = await runImport([
            .copyFromStandardInput(statement: "COPY t FROM stdin", lineNumber: 7, rows: PieceList(["1\n"]).data),
        ], sink: sink)

        guard case .failure(let error) = outcome,
              case .statementFailed(let statement, let line, _) = error as? PluginImportError
        else {
            Issue.record("Expected statementFailed, got \(outcome)")
            return
        }
        #expect(statement == "COPY t FROM stdin")
        #expect(line == 7)
        #expect(sink.calls.last == "ROLLBACK")
    }

    @Test("A Stop while rows are sent ends the COPY as a cancelled import")
    func stopDuringRows() async throws {
        let sink = CopySink()
        let progress = PluginImportProgress(progress: Progress())
        sink.onPiece = { progress.cancel() }
        let outcome = await runImport([
            .copyFromStandardInput(statement: "COPY t FROM stdin", lineNumber: 1, rows: PieceList(["1\n", "2\n", "3\n"]).data),
        ], sink: sink, progress: progress)

        guard case .failure(let error) = outcome else {
            Issue.record("Expected a cancellation, got \(outcome)")
            return
        }
        #expect(error is PluginImportCancellationError)
        #expect(sink.copied == Data("1\n".utf8))
    }

    @Test("A source with statements alone still runs through the default elements")
    func statementOnlySourceRuns() async throws {
        final class LegacySource: PluginImportSource, @unchecked Sendable {
            func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield((statement: "SELECT 1", lineNumber: 3))
                    continuation.finish()
                }
            }

            func fileURL() -> URL { URL(fileURLWithPath: "/dev/null") }
            func fileSizeBytes() -> Int64 { 0 }
        }

        var lines: [Int] = []
        for try await element in try await LegacySource().elements() {
            lines.append(element.lineNumber)
            #expect(element.statementText == "SELECT 1")
        }
        #expect(lines == [3])
    }
}
