//
//  ExportRoutineKindTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct DropRoutineCall: Equatable {
    let name: String
    let signature: String?
    let isFunction: Bool
}

private final class SameNamedRoutinesDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [DropRoutineCall] = []
    let spellsDrop: Bool

    init(spellsDrop: Bool = true) {
        self.spellsDrop = spellsDrop
    }

    var dropCalls: [DropRoutineCall] { lock.withLock { calls } }

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        [
            PluginRoutineInfo(name: "f", kind: .function, schema: schema, argumentSignature: "()"),
            PluginRoutineInfo(name: "f", kind: .procedure, schema: schema, argumentSignature: "()"),
        ]
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        "CREATE \(routine.kind.rawValue.uppercased()) f()"
    }

    func generateDropRoutineSQL(name: String, signature: String?, schema: String?, isFunction: Bool) -> String? {
        lock.withLock { calls.append(DropRoutineCall(name: name, signature: signature, isFunction: isFunction)) }
        guard spellsDrop else { return nil }
        return "DROP \(isFunction ? "FUNCTION" : "PROCEDURE") IF EXISTS \(name)"
    }
}

private final class TableRecordingFormat: ExportFormatPlugin, @unchecked Sendable {
    static let pluginName = "Table Recorder"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Records the objects it is handed"
    static let formatId = "table-recorder"
    static let formatDisplayName = "Table Recorder"
    static let defaultFileExtension = "txt"
    static let iconName = "doc"

    private(set) var receivedTables: [PluginExportTable] = []

    required init() {}

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        receivedTables = tables
        try Data().write(to: destination)
        return ExportFormatResult()
    }
}

struct ExportRoutineKindTests {
    private func pluginAdapter(_ stub: SameNamedRoutinesDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .mysql), pluginDriver: stub)
    }

    private func source(_ stub: SameNamedRoutinesDriver) -> ExportDataSourceAdapter {
        ExportDataSourceAdapter(driver: pluginAdapter(stub), databaseType: .mysql)
    }

    private func routine(tableType: String) -> PluginExportTable {
        PluginExportTable(
            name: "f", databaseName: "app", tableType: tableType, schema: "app", kind: .routine, identity: "()"
        )
    }

    @Test("The loader keeps each routine's own kind")
    func loaderKeepsTheKind() async {
        let items = await ExportObjectLoader.loadObjects(
            request: .init(containerName: "app", schema: "app", kinds: [.routine]),
            tables: [],
            driver: pluginAdapter(SameNamedRoutinesDriver())
        )

        #expect(items.map(\.kind) == [.routine, .routine])
        #expect(items.map(\.routineKind) == [.function, .procedure])
        #expect(items.map(\.identity) == ["()", "()"])
    }

    @Test("A procedure is dropped as a procedure and a function as a function")
    func dropAsksForTheRoutinesKind() {
        let stub = SameNamedRoutinesDriver()
        let adapter = source(stub)

        #expect(adapter.dropStatement(for: routine(tableType: "procedure")) == "DROP PROCEDURE IF EXISTS f")
        #expect(adapter.dropStatement(for: routine(tableType: "function")) == "DROP FUNCTION IF EXISTS f")
        #expect(stub.dropCalls == [
            DropRoutineCall(name: "f", signature: "()", isFunction: false),
            DropRoutineCall(name: "f", signature: "()", isFunction: true),
        ])
    }

    @Test("A routine whose kind was not carried gets no drop, and the driver is not asked to guess")
    func unknownKindWritesNoDrop() {
        let stub = SameNamedRoutinesDriver()

        #expect(source(stub).dropStatement(for: routine(tableType: PluginExportObjectKind.routine.rawValue)) == nil)
        #expect(stub.dropCalls.isEmpty)
    }

    @Test("A driver that cannot spell the drop leaves it out rather than writing DROP ROUTINE")
    func driverWithoutDropWritesNone() {
        let adapter = source(SameNamedRoutinesDriver(spellsDrop: false))
        let statements = ["procedure", "function", "routine"].map { adapter.dropStatement(for: routine(tableType: $0)) }

        #expect(statements == [nil, nil, nil])
    }

    @Test("A function and a procedure that share a name and signature each export their own definition")
    func definitionMatchesTheKind() async throws {
        let adapter = source(SameNamedRoutinesDriver())

        #expect(try await adapter.fetchObjectDDL(routine(tableType: "procedure")) == "CREATE PROCEDURE f()")
        #expect(try await adapter.fetchObjectDDL(routine(tableType: "function")) == "CREATE FUNCTION f()")
    }

    @Test("The export service hands the format a routine's own kind")
    @MainActor
    func serviceCarriesTheKind() async throws {
        let format = TableRecordingFormat()
        let driver = MockDatabaseDriver(connection: TestFixtures.makeConnection(type: .postgresql))
        let service = ExportService(driver: driver, databaseType: .postgresql) { requested in
            requested == TableRecordingFormat.formatId ? format : nil
        }
        var config = ExportConfiguration()
        config.formatId = TableRecordingFormat.formatId
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }

        try await service.export(
            objects: [
                ExportObjectItem(name: "p_proc", kind: .routine, identity: "(integer)", routineKind: .procedure),
                ExportObjectItem(name: "f_func", kind: .routine, identity: "(integer)", routineKind: .function),
                ExportObjectItem(name: "orders", kind: .table),
            ],
            config: config,
            to: url
        )

        #expect(format.receivedTables.map(\.tableType) == ["procedure", "function", "table"])
        #expect(format.receivedTables.map(\.kind) == [.routine, .routine, .table])
    }
}
