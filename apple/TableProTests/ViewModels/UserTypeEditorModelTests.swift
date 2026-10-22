//
//  UserTypeEditorModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct RefusedCheck: LocalizedError {
    let errorDescription: String?
}

private final class EditableDomainDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    private var reads = 0
    let refusing: String?
    let readsBeforeFailing: Int?

    init(refusing: String? = nil, readsBeforeFailing: Int? = nil) {
        self.refusing = refusing
        self.readsBeforeFailing = readsBeforeFailing
    }

    var executed: [String] { lock.withLock { queries } }
    var supportsTransactionalDDL: Bool { true }

    func execute(query: String) async throws -> PluginQueryResult {
        if let refusing, query.contains(refusing) {
            throw RefusedCheck(errorDescription: "column \"v\" of table \"t\" contains values that violate the new constraint")
        }
        lock.withLock { queries.append(query) }
        return .empty
    }

    func fetchUserDefinedType(_ type: PluginUserDefinedTypeInfo) async throws -> PluginUserDefinedTypeInfo {
        let count = lock.withLock { () -> Int in
            reads += 1
            return reads
        }
        if let readsBeforeFailing, count > readsBeforeFailing {
            throw RefusedCheck(errorDescription: "server closed the connection unexpectedly")
        }
        return PluginUserDefinedTypeInfo(
            name: type.name, kind: .domain, schema: "app", identity: type.identity,
            baseType: "integer", definition: "CREATE DOMAIN app.\(type.name) AS integer;", comment: "Counts"
        )
    }

    func alterUserDefinedTypeStatements(type: PluginUserDefinedTypeInfo, change: PluginUserDefinedTypeChange) -> [String]? {
        switch change {
        case .rename(let name): ["ALTER DOMAIN \(type.name) RENAME TO \(name)"]
        case .setComment(let comment): ["COMMENT ON DOMAIN \(type.name) IS '\(comment ?? "")'"]
        case .setNotNull(let value): ["ALTER DOMAIN \(type.name) \(value ? "SET" : "DROP") NOT NULL"]
        case .addCheck(let check, _): ["ALTER DOMAIN \(type.name) ADD CHECK (\(check.expression))"]
        default: nil
        }
    }
}

@MainActor
struct UserTypeEditorModelTests {
    private func install(_ driver: EditableDomainDriver) async throws -> (DatabaseConnection, UserTypeEditorModel) {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        DatabaseManager.shared.injectSession(
            ConnectionSession(connection: connection, driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)),
            for: connection.id
        )
        let scope = DatabaseScope(connectionId: connection.id, database: "app", schema: "app")
        let pooled = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        try await pooled.connect()
        MetadataConnectionPool.shared.injectEntry(pooled, scope: scope)
        let ref = DatabaseObjectRef(
            userType: UserDefinedTypeInfo(name: "posint", kind: .domain, schema: "app", identity: "42"),
            database: "app"
        )
        let model = UserTypeEditorModel(objectRef: ref, connection: connection, gate: AlwaysAllowGate())
        await model.load()
        return (connection, model)
    }

    private func uninstall(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("Loading reads the type and what the driver can change on it")
    func loadReadsSupport() async throws {
        let (connection, model) = try await install(EditableDomainDriver())
        defer { uninstall(connection) }

        #expect(model.loadState == .loaded)
        #expect(model.serverType?.comment == "Counts")
        #expect(model.support.rename && model.support.setNotNull && model.support.addCheck)
        #expect(!model.support.addLabel && !model.support.dropField)
    }

    @Test("A property edit replaces the queued one, and typing the server's value back removes it")
    func propertyEditsCoalesce() async throws {
        let (connection, model) = try await install(EditableDomainDriver())
        defer { uninstall(connection) }

        model.stage(.setComment("Count"))
        model.stage(.setComment("Counter"))
        #expect(model.changes.map { $0.change } == [.setComment("Counter")])

        model.stage(.setComment("Counts"))
        #expect(model.changes.isEmpty)
    }

    @Test("A rename stays last, so every other statement names the type the server knows")
    func renameStaysLast() async throws {
        let (connection, model) = try await install(EditableDomainDriver())
        defer { uninstall(connection) }

        model.stage(.rename(to: "counter"))
        model.stage(.setNotNull(true))
        #expect(model.changes.map { $0.change } == [.setNotNull(true), .rename(to: "counter")])
        #expect(try model.previewStatements() == [
            "ALTER DOMAIN posint SET NOT NULL",
            "ALTER DOMAIN posint RENAME TO counter"
        ])
    }

    @Test("A change that would not fit is reported before it is queued")
    func problemBeforeQueueing() async throws {
        let (connection, model) = try await install(EditableDomainDriver())
        defer { uninstall(connection) }

        #expect(model.problem(staging: [.addCheck(PluginUserDefinedTypeCheck(name: nil, expression: " "), validatesExistingValues: true)]) != nil)
        #expect(model.problem(staging: [.setNotNull(true)]) == nil)
    }

    @Test("A refused save keeps the queue and shows the server's answer on the change that caused it")
    func refusedSaveIsAttributed() async throws {
        let (connection, model) = try await install(EditableDomainDriver(refusing: "ADD CHECK"))
        defer { uninstall(connection) }
        model.stage(.setNotNull(true))
        model.stage(.addCheck(PluginUserDefinedTypeCheck(name: nil, expression: "VALUE > 0"), validatesExistingValues: true))
        let refused = try #require(model.changes.last)

        let outcome = await model.save(window: nil)

        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("violate the new constraint"))
        #expect(model.changes.count == 2)
        #expect(model.message(for: refused)?.contains("violate") == true)
        #expect(model.message(for: model.changes[0]) == nil)
        #expect(model.saveSummary != nil)
    }

    /// The copy on screen would be the old one, and a change that put a property back would be
    /// dropped as a no-op against it.
    @Test("A save whose reload fails holds editing until a reload succeeds")
    func failedReloadHoldsEditing() async throws {
        let (connection, model) = try await install(EditableDomainDriver(readsBeforeFailing: 1))
        defer { uninstall(connection) }
        model.stage(.setNotNull(true))

        let outcome = await model.save(window: nil)

        #expect(outcome == .applied)
        #expect(model.needsReload)
        model.stage(.setNotNull(false))
        #expect(model.changes.isEmpty)
    }

    @Test("A save that lands clears the queue and follows a rename")
    func appliedSaveFollowsRename() async throws {
        let driver = EditableDomainDriver()
        let (connection, model) = try await install(driver)
        defer { uninstall(connection) }
        var renamedTo: String?
        model.onRenamed = { renamedTo = $0.name }
        model.stage(.setNotNull(true))
        model.stage(.rename(to: "counter"))

        let outcome = await model.save(window: nil)

        #expect(outcome == .applied)
        #expect(model.changes.isEmpty)
        #expect(model.objectRef.name == "counter")
        #expect(renamedTo == "counter")
        #expect(driver.executed.contains("ALTER DOMAIN posint RENAME TO counter"))
    }
}
