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

    var providesBulkTriggerFetch: Bool { true }

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        try routines.get()
    }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        triggers
    }

    func fetchRoutineCreationScope(_ routine: PluginRoutineInfo) async throws -> PluginStatementScope? {
        try (scopes["\(routine.kind == .procedure ? "procedure" : "function") \(routine.name)"] ?? .success(nil)).get()
    }

    func fetchTriggerCreationScope(_ trigger: PluginTriggerInfo) async throws -> PluginStatementScope? {
        try (scopes["trigger \(trigger.name) on \(trigger.table ?? "")"] ?? .success(nil)).get()
    }
}

struct ObjectCopyCreationScopeReadTests {
    private func scope(_ mode: String) -> PluginStatementScope {
        PluginStatementScope(opening: ["SET sql_mode = '\(mode)'"], closing: ["SET sql_mode = @saved_sql_mode"])
    }

    private func makeTrigger(_ name: String, on table: String) -> PluginTriggerInfo {
        PluginTriggerInfo(name: name, table: table, timing: "BEFORE", event: "INSERT", statement: "SET NEW.d = NEW.d")
    }

    private func readScopes(
        _ selections: [ObjectCopySelection],
        from driver: CreationScopeSourceDriver
    ) async throws -> ObjectCopyCreationScopes {
        try await ObjectCopyPlanner.creationScopes(
            for: selections, triggerTables: [], schema: nil, using: driver
        )
    }

    @Test("Each routine and trigger gets the settings its source recorded, matched like its definition")
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

        let read = try await readScopes([procedure, function, stamp], from: driver)

        #expect(read.scopes[procedure.id] == scope("NO_ENGINE_SUBSTITUTION"))
        #expect(read.scopes[function.id] == scope("ANSI_QUOTES"))
        #expect(read.scopes[stamp.id] == scope("ONLY_FULL_GROUP_BY"))
        #expect(read.unreadable.isEmpty)
    }

    @Test("A failed read marks only its own object, and no settings is not a failure")
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

        let read = try await readScopes([failing, unrecorded], from: driver)

        #expect(read.unreadable == [failing.id])
        #expect(read.scopes.isEmpty)
    }

    @Test("A routine listing that fails marks every routine unreadable")
    func failedListingMarksEveryRoutine() async throws {
        let first = ObjectCopySelection(kind: .procedure, name: "one", schema: nil)
        let second = ObjectCopySelection(kind: .function, name: "two", schema: nil)
        let driver = CreationScopeSourceDriver(routines: .failure(ReadFailure()))

        let read = try await readScopes([first, second], from: driver)

        #expect(read.unreadable == [first.id, second.id])
        #expect(read.scopes.isEmpty)
    }

    @Test("Views and tables are not read for creation settings")
    func viewsAndTablesAreLeftAlone() async throws {
        let view = ObjectCopySelection(kind: .view, name: "recent", schema: nil)
        let table = ObjectCopySelection(kind: .table, name: "orders", schema: nil)

        let read = try await readScopes([view, table], from: CreationScopeSourceDriver(routines: .failure(ReadFailure())))

        #expect(read.scopes.isEmpty)
        #expect(read.unreadable.isEmpty)
    }
}
