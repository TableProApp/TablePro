import Foundation
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

// Stands in for `ExportRun`: the test decides when the run reports and how it ends.
nonisolated final class ScriptedExportRunner: ExportRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ExportOutcome, any Error>?
    private var pending: Result<ExportOutcome, any Error>?
    private var onProgress: (@Sendable (TransferProgress) -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelCount = 0

    func run(onProgress: @escaping @Sendable (TransferProgress) -> Void) async throws -> ExportOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let (ready, waiting) = lock.withLock { () -> (Result<ExportOutcome, any Error>?, [CheckedContinuation<Void, Never>]) in
                self.onProgress = onProgress
                defer { waiters = [] }
                if let pending {
                    self.pending = nil
                    return (pending, waiters)
                }
                self.continuation = continuation
                return (nil, waiters)
            }
            waiting.forEach { $0.resume() }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
        finish(.failure(CancellationError()))
    }

    func waitUntilRunning() async {
        await withCheckedContinuation { waiter in
            let running = lock.withLock { () -> Bool in
                guard onProgress == nil else { return true }
                waiters.append(waiter)
                return false
            }
            if running { waiter.resume() }
        }
    }

    func report(_ progress: TransferProgress) {
        let handler = lock.withLock { onProgress }
        handler?(progress)
    }

    func finish(_ result: Result<ExportOutcome, any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<ExportOutcome, any Error>? in
            guard let continuation else {
                pending = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        waiting?.resume(with: result)
    }
}

nonisolated struct ScriptedExportFailure: LocalizedError {
    var errorDescription: String? { "The server went away." }
}

@MainActor
struct MobileExportModelTests {
    private func input(scopes: [ExportScopeOption], type: DatabaseType = .postgresql) -> MobileExportInput {
        MobileExportInput(
            title: "Export", fileName: "orders", connectionId: UUID(), databaseType: type, database: "shop",
            schema: "public", safeModeLevel: .off, scopes: scopes
        )
    }

    private func object(_ name: String, kind: PluginExportObjectKind) -> PluginExportTable {
        PluginExportTable(
            name: name, databaseName: "shop", tableType: kind.rawValue,
            optionValues: MobileExportFormats.sql.defaultTableOptionValues(), schema: "public", kind: kind
        )
    }

    private func environment(
        runner: ScriptedExportRunner = ScriptedExportRunner(),
        objects: [PluginExportTable] = [],
        requests: RequestLog = RequestLog()
    ) -> MobileExportEnvironment {
        MobileExportEnvironment(
            formats: { MobileExportFormats.available(for: $0) },
            loadObjects: { _, _ in objects },
            makeRunner: { request, _ in
                requests.requests.append(request)
                return runner
            },
            sessionDriver: { nil }
        )
    }

    private func outcomeFolder() throws -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("orders.csv")
        try Data("id\n1\n".utf8).write(to: file)
        return (folder, file)
    }

    @Test("The formats offered follow the engine, in the Mac's order", arguments: [
        (DatabaseType.postgresql, ["csv", "json", "sql", "xlsx", "md"]),
        (DatabaseType.mongodb, ["csv", "json", "xlsx", "md", "mql"]),
        (DatabaseType.redis, ["csv", "json", "xlsx", "md"])
    ])
    func formatsPerEngine(type: DatabaseType, expected: [String]) {
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .result, source: .query("SELECT 1"))], type: type),
            environment: environment()
        )
        #expect(model.formatChoices.map { $0.id } == expected)
        #expect(model.formatId == expected.first)
    }

    @Test("An export runs, shares, keeps the file for Share Again, and removes it when the sheet closes")
    func runShareAndClose() async throws {
        let runner = ScriptedExportRunner()
        let requests = RequestLog()
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .result, source: .query("SELECT * FROM orders"))]),
            environment: environment(runner: runner, requests: requests)
        )
        #expect(model.canExport)

        model.start()
        #expect(model.phase == .running(TransferProgress(stage: .preparing)))
        #expect(model.canExport == false)
        await runner.waitUntilRunning()

        var progress = TransferProgress(stage: .running)
        progress.completedUnits = 12_400
        progress.totalUnits = 48_000
        runner.report(progress)
        await ObservedCondition.wait { model.phase == .running(progress) }

        let (folder, file) = try outcomeFolder()
        runner.finish(.success(ExportOutcome(folder: folder, files: [file], rowsWritten: 48_000, warnings: [], notes: [])))
        await ObservedCondition.wait { model.phase == .sharing }
        #expect(model.finished?.files == [file])
        #expect(model.finished?.rowsWritten == 48_000)
        if case .query(let select)? = requests.requests.first?.source {
            #expect(select.statement(on: RecordingTransferDriver()) == "SELECT * FROM orders")
        } else {
            Issue.record("The result was not exported as a query")
        }

        model.shareEnded()
        #expect(model.phase == .finished)
        #expect(FileManager.default.fileExists(atPath: file.path))

        model.close()
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
        #expect(model.finished == nil)
    }

    @Test("Cancel stops the run and ends in the cancelled state")
    func cancel() async {
        let runner = ScriptedExportRunner()
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .result, source: .query("SELECT 1"))]),
            environment: environment(runner: runner)
        )
        model.start()
        await runner.waitUntilRunning()

        model.cancel()
        await ObservedCondition.wait { model.phase == .cancelled }
        #expect(runner.cancelCount == 1)

        model.reconfigure()
        #expect(model.phase == .configuring)
    }

    @Test("A failed run says why, and Try Again goes back to the options")
    func failure() async {
        let runner = ScriptedExportRunner()
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .result, source: .query("SELECT 1"))]),
            environment: environment(runner: runner)
        )
        model.start()
        runner.finish(.failure(ScriptedExportFailure()))

        await ObservedCondition.wait { model.phase == .failed("The server went away.") }
        model.reconfigure()
        #expect(model.phase == .configuring)
    }

    @Test("A database export lists every object by kind in dump order, all picked, and sends only what writes something")
    func databaseObjects() async {
        let requests = RequestLog()
        let runner = ScriptedExportRunner()
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .database, source: .database)]),
            environment: environment(
                runner: runner,
                objects: [
                    object("orders_view", kind: .view), object("orders", kind: .table),
                    object("order_status", kind: .userType), object("customers", kind: .table)
                ],
                requests: requests
            )
        )
        model.selectFormat(type(of: MobileExportFormats.sql).formatId)
        await model.loadObjectsIfNeeded()

        #expect(model.objectGroups.map { $0.kind } == [.userType, .table, .view])
        #expect(model.exportableObjects.count == 4)

        let typeRow = model.objectGroups[0].rows[0].id
        for column in model.optionColumns.indices {
            model.setOption(false, at: column, for: typeRow)
        }
        model.setSelected(false, kind: .view)
        #expect(model.exportableObjects.map { $0.name }.sorted() == ["customers", "orders"])

        model.start()
        if case .objects(let objects)? = requests.requests.first?.source {
            #expect(objects.map { $0.name }.sorted() == ["customers", "orders"])
        } else {
            Issue.record("The database was not exported as objects")
        }
        model.cancel()
        await ObservedCondition.wait { model.phase == .cancelled }
    }

    @Test("A table export shows and picks only that table")
    func tableObjects() async {
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .wholeTable, source: .table("orders"))]),
            environment: environment(objects: [object("customers", kind: .table), object("orders", kind: .table)])
        )
        await model.loadObjectsIfNeeded()

        #expect(model.objectGroups.flatMap { $0.rows }.map { $0.object.name } == ["orders"])
        #expect(model.exportableObjects.map { $0.name } == ["orders"])
    }

    @Test("Another format gives every object that format's default options")
    func formatChangeResetsOptions() async {
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .database, source: .database)]),
            environment: environment(objects: [object("orders", kind: .table)])
        )
        model.selectFormat(type(of: MobileExportFormats.sql).formatId)
        await model.loadObjectsIfNeeded()
        let row = model.objectGroups[0].rows[0].id
        model.setOption(false, at: 0, for: row)
        #expect(model.objectGroups[0].rows[0].object.optionValues == [false, true, true])

        model.selectFormat(type(of: MobileExportFormats.csv).formatId)
        #expect(model.objectGroups[0].rows[0].object.optionValues == MobileExportFormats.csv.defaultTableOptionValues())
    }

    @Test("Another format shows the kinds it writes with the selection they had, each with only the options it takes")
    func formatChangeKeepsEveryKind() async throws {
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .database, source: .database)]),
            environment: environment(objects: [
                object("orders", kind: .table), object("total", kind: .routine), object("audit", kind: .trigger)
            ])
        )
        await model.loadObjectsIfNeeded()
        #expect(model.objectGroups.map { $0.kind } == [.table])

        model.selectFormat(type(of: MobileExportFormats.sql).formatId)
        #expect(Set(model.objectGroups.map { $0.kind }) == [.table, .routine, .trigger])
        let rows = model.objectGroups.flatMap { $0.rows }
        let routine = try #require(rows.first { $0.object.kind == .routine })
        #expect(routine.isSelected)
        #expect(routine.object.optionValues == [true, true, false])
        #expect(rows.first { $0.object.kind == .table }?.object.optionValues == [true, true, true])

        model.setSelected(false, for: routine.id)
        model.selectFormat(type(of: MobileExportFormats.csv).formatId)
        model.selectFormat(type(of: MobileExportFormats.sql).formatId)
        #expect(model.objectGroups.flatMap { $0.rows }.first { $0.id == routine.id }?.isSelected == false)
    }

    @Test("A function and a procedure with one name are two rows, and picking one leaves the other")
    func sameNamedRoutinesAreTwoRows() async throws {
        let function = PluginExportTable(
            name: "total", databaseName: "shop", tableType: "function", schema: nil, kind: .routine
        )
        let procedure = PluginExportTable(
            name: "total", databaseName: "shop", tableType: "procedure", schema: nil, kind: .routine
        )
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .database, source: .database)]),
            environment: environment(objects: [function, procedure])
        )
        model.selectFormat(type(of: MobileExportFormats.sql).formatId)
        await model.loadObjectsIfNeeded()

        let rows = model.objectGroups.flatMap { $0.rows }
        #expect(Set(rows.map(\.id)).count == 2)
        let procedureRow = try #require(rows.first { $0.object.tableType == "procedure" })
        model.setSelected(false, for: procedureRow.id)

        #expect(model.exportableObjects.map(\.tableType) == ["function"])
    }

    @Test("Export hands the run its own copy of the format, and the live Safe Mode level")
    func exportRunsWithAFrozenPlugin() async {
        let plugins = PluginLog()
        let requests = RequestLog()
        var live = environment(requests: requests)
        live.makeRunner = { request, plugin in
            requests.requests.append(request)
            plugins.plugins.append(plugin)
            return ScriptedExportRunner()
        }
        live.safeModeLevel = { .readOnly }
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .result, source: .query("SELECT 1"))]),
            environment: live
        )

        model.start()

        let used = plugins.plugins.first
        #expect(used != nil)
        #expect(used.map { $0 !== MobileExportFormats.csv } == true)
        #expect(requests.requests.first?.safeModeLevel == .readOnly)
        model.close()
    }

    @Test("Without a file name nothing exports")
    func emptyFileName() {
        let model = MobileExportModel(
            input: input(scopes: [ExportScopeOption(kind: .result, source: .query("SELECT 1"))]),
            environment: environment()
        )
        model.fileName = "  "
        #expect(model.canExport == false)
    }
}

@MainActor
final class RequestLog {
    var requests: [ExportRequest] = []
}

@MainActor
final class PluginLog {
    var plugins: [any ExportFormatPlugin] = []
}
