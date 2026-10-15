//
//  ExportDataSourceAdapterSessionScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CreationScopeDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var currentSchema: String? { nil }

    private(set) var openedPurposes: [PluginSessionPurpose] = []
    private(set) var closedScopes: [PluginSessionScope] = []
    private(set) var scopedRoutines: [String] = []
    private(set) var scopedTriggers: [String] = []
    private(set) var scopedEvents: [String] = []

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        openedPurposes.append(purpose)
        return PluginSessionScope(
            purpose: purpose,
            saved: [PluginSessionSetting(name: "time_zone", value: "+07:00")],
            applied: [PluginSessionSetting(name: "time_zone", value: "+00:00")]
        )
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        closedScopes.append(scope)
    }

    func fetchRoutines(schema: String?) async throws -> [PluginRoutineInfo] {
        [
            PluginRoutineInfo(name: "add_course", kind: .procedure, schema: schema, argumentSignature: "IN d DATE"),
            PluginRoutineInfo(name: "add_course", kind: .procedure, schema: schema, argumentSignature: "IN d DATETIME"),
        ]
    }

    func fetchAllTriggers(schema: String?) async throws -> [PluginTriggerInfo] {
        [
            PluginTriggerInfo(name: "stamp", table: "courses", timing: "BEFORE", event: "INSERT", statement: "SET x = 1"),
            PluginTriggerInfo(name: "stamp", table: "lessons", timing: "BEFORE", event: "INSERT", statement: "SET y = 1"),
        ]
    }

    func fetchEvents(schema: String?) async throws -> [PluginEventInfo] {
        [PluginEventInfo(name: "purge", schema: schema)]
    }

    func fetchRoutineCreationScope(_ routine: PluginRoutineInfo) async throws -> PluginStatementScope? {
        scopedRoutines.append(routine.argumentSignature ?? "")
        return Self.scope(for: "routine")
    }

    func fetchTriggerCreationScope(_ trigger: PluginTriggerInfo) async throws -> PluginStatementScope? {
        scopedTriggers.append(trigger.table ?? "")
        return Self.scope(for: "trigger")
    }

    func fetchEventCreationScope(_ event: PluginEventInfo) async throws -> PluginStatementScope? {
        scopedEvents.append(event.name)
        return Self.scope(for: "event")
    }

    static func scope(for kind: String) -> PluginStatementScope {
        PluginStatementScope(opening: ["SET @\(kind) = 1"], closing: ["SET @\(kind) = 0"])
    }
}

private final class PlainDatabaseDriver: PluginDriverStub, @unchecked Sendable {}

struct ExportDataSourceAdapterSessionScopeTests {
    private func adapter(_ driver: any PluginDatabaseDriver) -> ExportDataSourceAdapter {
        let connection = TestFixtures.makeConnection(type: .mysql)
        return ExportDataSourceAdapter(
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver),
            databaseType: .mysql
        )
    }

    private func object(
        _ name: String,
        kind: PluginExportObjectKind,
        identity: String? = nil,
        parentTable: String? = nil
    ) -> PluginExportTable {
        PluginExportTable(
            name: name,
            databaseName: "school",
            tableType: kind.rawValue,
            schema: nil,
            kind: kind,
            identity: identity,
            parentTable: parentTable
        )
    }

    @Test("Opening and closing a scope reaches the driver the export reads from")
    func scopeCallsReachTheDriver() async throws {
        let driver = CreationScopeDriver()
        let source = adapter(driver)

        let scope = try #require(try await source.openSessionScope(for: .verbatimRead))
        try await source.closeSessionScope(scope)

        #expect(driver.openedPurposes == [.verbatimRead])
        #expect(driver.closedScopes == [scope])
        #expect(scope.appliedValue(of: "TIME_ZONE") == "+00:00")
    }

    @Test("A driver with nothing to hold opens no scope")
    func driverWithoutScopesOpensNone() async throws {
        let source = adapter(PlainDatabaseDriver())

        #expect(try await source.openSessionScope(for: .verbatimRead) == nil)
    }

    @Test("A routine's scope comes from the overload the export item names")
    func routineScopeMatchesTheSignature() async throws {
        let driver = CreationScopeDriver()
        let source = adapter(driver)

        let scope = try await source.fetchCreationScope(
            object("add_course", kind: .routine, identity: "IN d DATETIME")
        )

        #expect(scope == CreationScopeDriver.scope(for: "routine"))
        #expect(driver.scopedRoutines == ["IN d DATETIME"])
    }

    @Test("A trigger's scope comes from the trigger on the export item's table")
    func triggerScopeMatchesTheTable() async throws {
        let driver = CreationScopeDriver()
        let source = adapter(driver)

        let scope = try await source.fetchCreationScope(object("stamp", kind: .trigger, parentTable: "lessons"))

        #expect(scope == CreationScopeDriver.scope(for: "trigger"))
        #expect(driver.scopedTriggers == ["lessons"])
    }

    @Test("An event's scope comes from the event of that name")
    func eventScopeMatchesTheName() async throws {
        let driver = CreationScopeDriver()
        let source = adapter(driver)

        let scope = try await source.fetchCreationScope(object("purge", kind: .event))

        #expect(scope == CreationScopeDriver.scope(for: "event"))
        #expect(driver.scopedEvents == ["purge"])
    }

    @Test("A table, a view or a sequence has no creation scope")
    func otherKindsHaveNone() async throws {
        let driver = CreationScopeDriver()
        let source = adapter(driver)

        for kind in [PluginExportObjectKind.table, .view, .sequence, .userType] {
            #expect(try await source.fetchCreationScope(object("courses", kind: kind)) == nil)
        }
        #expect(driver.scopedRoutines.isEmpty)
        #expect(driver.scopedTriggers.isEmpty)
        #expect(driver.scopedEvents.isEmpty)
    }

    @Test("An object the driver does not list fails the way its definition does")
    func unmatchedObjectThrows() async {
        let source = adapter(CreationScopeDriver())

        await #expect(throws: PluginObjectSourceError.self) {
            try await source.fetchCreationScope(object("add_course", kind: .routine, identity: "IN d TIME"))
        }
        await #expect(throws: PluginObjectSourceError.self) {
            try await source.fetchCreationScope(object("stamp", kind: .trigger, parentTable: "rooms"))
        }
        await #expect(throws: PluginObjectSourceError.self) {
            try await source.fetchCreationScope(object("archive", kind: .event))
        }
    }

    @Test("A source with no plugin driver has no creation scope")
    func noPluginDriverHasNone() async throws {
        let source = ExportDataSourceAdapter(driver: MockDatabaseDriver(), databaseType: .mysql)

        #expect(try await source.fetchCreationScope(object("purge", kind: .event)) == nil)
    }
}
