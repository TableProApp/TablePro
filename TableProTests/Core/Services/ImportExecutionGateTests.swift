//
//  ImportExecutionGateTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

private actor RecordingGate: ExecutionGate {
    private let decide: @Sendable (OperationRequest) -> OperationDecision
    private(set) var requests: [OperationRequest] = []

    init(decide: @escaping @Sendable (OperationRequest) -> OperationDecision) {
        self.decide = decide
    }

    func authorize(_ request: OperationRequest) async -> OperationDecision {
        requests.append(request)
        return decide(request)
    }
}

private final class RecordingImportPlugin: ImportFormatPlugin {
    static let pluginName = "Recording Import"
    static let pluginVersion = "1.0"
    static let pluginDescription = "An import format that records whether it ran"
    static let formatId = "tablepro-tests-gated-import"
    static let formatDisplayName = "Recording"
    static let acceptedFileExtensions = ["csv"]
    static let iconName = "tablecells"
    static let requiresTargetTable = true

    static let runs = OSAllocatedUnfairLock(initialState: 0)

    required init() {}

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult {
        Self.runs.withLock { $0 += 1 }
        return PluginImportResult(executedStatements: 0, executionTime: 0)
    }
}

private actor SilentHistory: QueryHistoryRecording {
    private(set) var requests: [QueryHistoryRecordRequest] = []

    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        requests.append(request)
        return true
    }
}

@Suite("Imported and transferred rows pass the execution gate", .serialized)
@MainActor
struct ImportExecutionGateTests {
    private static func receipt(for connectionId: UUID) -> OperationReceipt {
        OperationReceipt(
            connectionId: connectionId, kind: .schemaMutation, effectiveWrite: true, grantedAt: Date(), token: UUID()
        )
    }

    private func importFile(
        gate: RecordingGate,
        connection: DatabaseConnection,
        authorization: OperationReceipt? = nil
    ) async throws -> (history: SilentHistory, error: (any Error)?) {
        PluginManager.shared.importPlugins[RecordingImportPlugin.formatId] = RecordingImportPlugin()
        defer { PluginManager.shared.importPlugins[RecordingImportPlugin.formatId] = nil }
        RecordingImportPlugin.runs.withLock { $0 = 0 }

        let history = SilentHistory()
        let service = ImportService(connection: connection, historyRecorder: history, gate: gate)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gated-import-\(UUID().uuidString)")
            .appendingPathExtension("csv")
        try Data("id\n1\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await service.importFile(
                from: file,
                formatId: RecordingImportPlugin.formatId,
                encoding: .utf8,
                scope: DatabaseScope(connectionId: connection.id, database: connection.database, schema: nil),
                targetTable: "orders",
                authorization: authorization
            )
            return (history, nil)
        } catch {
            return (history, error)
        }
    }

    @Test("A file import asks the gate once, as an import, before anything runs")
    func importAsksTheGate() async throws {
        let connection = TestFixtures.makeConnection(database: "shop")
        let gate = RecordingGate { _ in .denied(reason: "Read-only") }

        let (history, error) = try await importFile(gate: gate, connection: connection)

        guard case ExecutionGateError.denied("Read-only")? = error as? ExecutionGateError else {
            Issue.record("Expected the gate's refusal, got \(String(describing: error))")
            return
        }
        let requests = await gate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.connectionId == connection.id)
        #expect(requests.first?.kind == .importData)
        #expect(requests.first?.caller == .importPipeline)
        #expect(RecordingImportPlugin.runs.withLock { $0 } == 0)
        #expect(await history.requests.isEmpty)
    }

    @Test("A Cancel at the gate stays a cancel")
    func cancelStaysACancel() async throws {
        let connection = TestFixtures.makeConnection(database: "shop")
        let gate = RecordingGate { _ in .denied(reason: "Cancelled", cause: .cancelledByUser) }

        let (_, error) = try await importFile(gate: gate, connection: connection)

        guard case ExecutionGateError.cancelledByUser? = error as? ExecutionGateError else {
            Issue.record("Expected a cancel, got \(String(describing: error))")
            return
        }
        #expect(RecordingImportPlugin.runs.withLock { $0 } == 0)
    }

    @Test("A run the gate already granted, for the new table, is not asked again")
    func grantedRunIsNotAskedTwice() async throws {
        let connection = TestFixtures.makeConnection(database: "shop")
        let gate = RecordingGate { _ in .denied(reason: "Asked twice") }

        let (_, error) = try await importFile(
            gate: gate, connection: connection, authorization: Self.receipt(for: connection.id)
        )

        #expect(await gate.requests.isEmpty)
        #expect(!(error is ExecutionGateError))
    }

    @Test("A grant for another connection does not cover this one")
    func grantForAnotherConnectionIsIgnored() async throws {
        let connection = TestFixtures.makeConnection(database: "shop")
        let gate = RecordingGate { _ in .denied(reason: "Read-only") }

        let (_, error) = try await importFile(gate: gate, connection: connection, authorization: Self.receipt(for: UUID()))

        #expect(await gate.requests.count == 1)
        #expect(error is ExecutionGateError)
        #expect(RecordingImportPlugin.runs.withLock { $0 } == 0)
    }

    @Test("Transfer To asks the gate for the destination before it takes either driver")
    func transferAsksTheGate() async throws {
        let destinationId = UUID()
        let gate = RecordingGate { _ in .denied(reason: "Read-only") }
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "orders", kind: .table)],
            sourceType: .mysql,
            destinationType: .postgresql,
            deleteExistingRows: true
        )

        await #expect(throws: ExecutionGateError.self) {
            try await TableTransferService().run(
                request: request,
                source: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
                destination: DatabaseScope(connectionId: destinationId, database: "archive", schema: nil),
                operationDescription: "Transfer 1 table into archive?",
                confirmedByCaller: true,
                gate: gate
            )
        }

        let requests = await gate.requests
        #expect(requests.count == 1)
        #expect(requests.first?.connectionId == destinationId)
        #expect(requests.first?.databaseType == .postgresql)
        #expect(requests.first?.kind == .destructiveQuery)
        #expect(requests.first?.caller == .importPipeline)
        #expect(requests.first?.capabilities.contains(.confirmationPreCleared) == true)
    }

    @Test("A transfer that keeps the destination's rows is an import the gate confirms itself")
    func transferWithoutDeleteIsAnImport() async throws {
        let gate = RecordingGate { _ in .denied(reason: "Read-only") }
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "orders", kind: .table)],
            sourceType: .mysql,
            destinationType: .mysql
        )

        await #expect(throws: ExecutionGateError.self) {
            try await TableTransferService().run(
                request: request,
                source: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
                destination: DatabaseScope(connectionId: UUID(), database: "archive", schema: nil),
                operationDescription: "Transfer 1 table into archive?",
                confirmedByCaller: false,
                gate: gate
            )
        }

        let requests = await gate.requests
        #expect(requests.first?.kind == .importData)
        #expect(requests.first?.capabilities.contains(.confirmationPreCleared) == false)
    }

    /// The sink writes straight to the driver, so whatever builds one is where the gate has to be.
    @Test("Only the two runs that authorize first build the import sink")
    func onlyAuthorizedRunsBuildTheSink() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            root.deleteLastPathComponent()
        }
        let appRoot = root.appendingPathComponent("TablePro")
        let enumerator = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
        var builders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            guard source.contains("ImportDataSinkAdapter(") else { continue }
            builders.append(url.lastPathComponent)
            #expect(source.contains("gate.authorize("), "\(url.lastPathComponent) builds the sink without the gate")
        }
        #expect(builders.sorted() == ["ImportService.swift", "TableTransferService.swift"])
    }
}
