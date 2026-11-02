//
//  ObjectCopyCreationScopeReadTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct ReadFailure: Error {}

private final class CreationScopeSourceDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var scopeReads = 0
    private let routines: Result<[PluginRoutineInfo], any Error>
    private let triggers: [PluginTriggerInfo]
    private let scopes: [String: Result<PluginStatementScope?, any Error>]

    init(
        routines: Result<[PluginRoutineInfo], any Error> = .success([]),
        triggers: [PluginTriggerInfo] = [],
        scopes: [String: Result<PluginStatementScope?, any Error>] = [:]
    ) {
        self.routines = routines
        self.triggers = triggers
        self.scopes = scopes
    }

    var scopeReadCount: Int { lock.withLock { scopeReads } }

    var providesBulkTriggerFetch: Bool { true }

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try routines.get()
    }

    func fetchRoutineDDL(_ routine: PluginRoutineInfo) async throws -> String {
        "CREATE \(routine.kind == .procedure ? "PROCEDURE" : "FUNCTION") `\(routine.name)`() SELECT 1"
    }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        triggers
    }

    func fetchRoutineCreationScope(_ routine: PluginRoutineInfo) async throws -> PluginStatementScope? {
        lock.withLock { scopeReads += 1 }
        return try (scopes["\(routine.kind == .procedure ? "procedure" : "function") \(routine.name)"] ?? .success(nil)).get()
    }

    func fetchTriggerCreationScope(_ trigger: PluginTriggerInfo) async throws -> PluginStatementScope? {
        lock.withLock { scopeReads += 1 }
        return try (scopes["trigger \(trigger.name) on \(trigger.table ?? "")"] ?? .success(nil)).get()
    }
}

struct ObjectCopyCreationScopeReadTests {
    private func scope(_ mode: String) -> PluginStatementScope {
        PluginStatementScope(opening: ["SET sql_mode = '\(mode)'"], closing: ["SET sql_mode = @saved_sql_mode"])
    }

    private func makeTrigger(_ name: String, on table: String) -> PluginTriggerInfo {
        PluginTriggerInfo(
            name: name, table: table, timing: "BEFORE", event: "INSERT", statement: "SET NEW.d = NEW.d",
            definition: "CREATE TRIGGER `\(name)` BEFORE INSERT ON `\(table)` FOR EACH ROW SET NEW.d = NEW.d"
        )
    }

    private func read(
        _ selections: [ObjectCopySelection],
        views: [TableStructureRead] = [],
        triggerTables: [String] = [],
        from driver: CreationScopeSourceDriver
    ) async throws -> [String: RoutineSourceRead] {
        try await ObjectCopyPlanner.sourceDefinitionReads(
            for: selections,
            views: views,
            triggerTables: triggerTables,
            schema: nil,
            endpointName: "shop",
            using: driver
        )
    }

    @Test("Each routine and trigger carries the settings its source recorded, read with its definition")
    func routinesAndTriggersGetTheirOwnSettings() async throws {
        let procedure = ObjectCopySelection(kind: .procedure, name: "Tally", schema: nil)
        let function = ObjectCopySelection(kind: .function, name: "tally", schema: nil)
        let stamp = ObjectCopySelection(kind: .trigger, name: "stamp", schema: nil, owner: "orders")
        let driver = CreationScopeSourceDriver(
            routines: .success([
                PluginRoutineInfo(name: "tally", kind: .procedure),
                PluginRoutineInfo(name: "tally", kind: .function)
            ]),
            triggers: [makeTrigger("stamp", on: "invoices"), makeTrigger("stamp", on: "orders")],
            scopes: [
                "procedure tally": .success(scope("NO_ENGINE_SUBSTITUTION")),
                "function tally": .success(scope("ANSI_QUOTES")),
                "trigger stamp on invoices": .success(scope("TRADITIONAL")),
                "trigger stamp on orders": .success(scope("ONLY_FULL_GROUP_BY"))
            ]
        )

        let reads = try await read(
            [procedure, function, stamp], triggerTables: ["invoices", "orders"], from: driver
        )

        #expect(reads[procedure.id]?.creationScope == scope("NO_ENGINE_SUBSTITUTION"))
        #expect(reads[function.id]?.creationScope == scope("ANSI_QUOTES"))
        #expect(reads[stamp.id]?.creationScope == scope("ONLY_FULL_GROUP_BY"))
        #expect(reads.values.allSatisfy { !$0.creationScopeUnreadable })
    }

    @Test("A failed settings read marks only its own object, and keeps its definition")
    func failedReadMarksOnlyItsObject() async throws {
        let failing = ObjectCopySelection(kind: .procedure, name: "broken", schema: nil)
        let unrecorded = ObjectCopySelection(kind: .procedure, name: "plain", schema: nil)
        let driver = CreationScopeSourceDriver(
            routines: .success([
                PluginRoutineInfo(name: "broken", kind: .procedure),
                PluginRoutineInfo(name: "plain", kind: .procedure)
            ]),
            scopes: ["procedure broken": .failure(ReadFailure())]
        )

        let reads = try await read([failing, unrecorded], from: driver)

        #expect(reads[failing.id]?.creationScopeUnreadable == true)
        #expect(reads[failing.id]?.failure == nil)
        #expect(reads[unrecorded.id]?.creationScopeUnreadable == false)
        #expect(reads.values.allSatisfy { $0.creationScope == nil })
    }

    @Test("A routine listing that fails leaves every routine without a definition and reads no settings")
    func failedListingMarksEveryRoutine() async throws {
        let first = ObjectCopySelection(kind: .procedure, name: "one", schema: nil)
        let second = ObjectCopySelection(kind: .function, name: "two", schema: nil)
        let driver = CreationScopeSourceDriver(routines: .failure(ReadFailure()))

        let reads = try await read([first, second], from: driver)

        #expect(reads[first.id]?.failure != nil)
        #expect(reads[second.id]?.failure != nil)
        #expect(driver.scopeReadCount == 0)
    }

    @Test("Views are not read for creation settings")
    func viewsAreLeftAlone() async throws {
        let view = ObjectCopySelection(kind: .view, name: "recent", schema: nil)
        let read = TableStructureRead(
            table: PluginTableInfo(name: "recent", type: "VIEW", schema: nil, comment: nil),
            columns: [], indexes: [], foreignKeys: [], metadata: nil, failure: nil, objectIndexes: nil
        )
        let driver = CreationScopeSourceDriver(routines: .failure(ReadFailure()))

        let reads = try await self.read([view], views: [read], from: driver)

        #expect(reads[view.id]?.creationScope == nil)
        #expect(reads[view.id]?.creationScopeUnreadable == false)
        #expect(driver.scopeReadCount == 0)
    }
}
