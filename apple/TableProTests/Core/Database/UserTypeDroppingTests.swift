//
//  UserTypeDroppingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class TypeDropStubDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    let droppableKinds: Set<PluginUserDefinedTypeKind>

    init(droppableKinds: Set<PluginUserDefinedTypeKind> = [.udt]) {
        self.droppableKinds = droppableKinds
    }

    var executedQueries: [String] {
        lock.withLock { queries }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { queries.append(query) }
        return .empty
    }

    func generateDropTypeSQL(type: PluginUserDefinedTypeInfo) -> String? {
        guard droppableKinds.contains(type.kind) else { return nil }
        return "DROP TYPE \(type.schema ?? "?").\(type.name)"
    }
}

private struct CancellingGate: ExecutionGate {
    func authorize(_ request: OperationRequest) async -> OperationDecision {
        .denied(reason: "Operation cancelled by user", cause: .cancelledByUser)
    }
}

@MainActor
struct UserTypeDroppingTests {
    private let type = UserDefinedTypeInfo(name: "address", kind: .udt, schema: "shop")

    private func install() async throws -> (
        connection: DatabaseConnection,
        scope: DatabaseScope,
        session: TypeDropStubDriver,
        pooled: TypeDropStubDriver
    ) {
        let connection = TestFixtures.makeConnection(database: "shop", type: .cassandra)
        let sessionStub = TypeDropStubDriver()
        DatabaseManager.shared.injectSession(
            ConnectionSession(
                connection: connection,
                driver: PluginDriverAdapter(connection: connection, pluginDriver: sessionStub)
            ),
            for: connection.id
        )
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let pooledStub = TypeDropStubDriver()
        let pooledAdapter = PluginDriverAdapter(connection: connection, pluginDriver: pooledStub)
        try await pooledAdapter.connect()
        MetadataConnectionPool.shared.injectEntry(pooledAdapter, scope: scope)
        return (connection, scope, sessionStub, pooledStub)
    }

    private func uninstall(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    @Test("The drop is built and run on the scope's own connection, never the session's")
    func dropRunsOnThePooledConnection() async throws {
        let installed = try await install()
        defer { uninstall(installed.connection) }

        try await UserTypeDropping.drop(
            type,
            in: installed.scope,
            connection: installed.connection,
            gate: AlwaysAllowGate()
        )

        #expect(installed.pooled.executedQueries == ["DROP TYPE shop.address"])
        #expect(installed.session.executedQueries.isEmpty)
    }

    @Test("A refused drop runs nothing and says why")
    func refusedDropRunsNothing() async throws {
        let installed = try await install()
        defer { uninstall(installed.connection) }

        await #expect(throws: ExecutionGateError.self) {
            try await UserTypeDropping.drop(
                type,
                in: installed.scope,
                connection: installed.connection,
                gate: AlwaysDenyGate()
            )
        }
        #expect(installed.pooled.executedQueries.isEmpty)
    }

    @Test("Cancelling the confirmation is reported as a cancel, so the caller stays quiet")
    func cancelledDropIsACancel() async throws {
        let installed = try await install()
        defer { uninstall(installed.connection) }

        var cancelled = false
        do {
            try await UserTypeDropping.drop(type, in: installed.scope, connection: installed.connection, gate: CancellingGate())
        } catch ExecutionGateError.cancelledByUser {
            cancelled = true
        }
        #expect(cancelled)
        #expect(installed.pooled.executedQueries.isEmpty)
    }

    @Test("A kind the driver has no statement for is refused before the gate is asked")
    func undroppableKindIsUnsupported() async throws {
        let installed = try await install()
        defer { uninstall(installed.connection) }
        let composite = UserDefinedTypeInfo(name: "point", kind: .composite, schema: "shop")

        await #expect(throws: DatabaseObjectCommandError.unsupported) {
            try await UserTypeDropping.drop(
                composite,
                in: installed.scope,
                connection: installed.connection,
                gate: AlwaysAllowGate()
            )
        }
        #expect(installed.pooled.executedQueries.isEmpty)
    }

    @Test("Cascade is refused before the gate where the driver has no cascading drop")
    func cascadeWithoutSupportIsUnsupported() async throws {
        let installed = try await install()
        defer { uninstall(installed.connection) }

        await #expect(throws: DatabaseObjectCommandError.unsupported) {
            try await UserTypeDropping.drop(
                type,
                cascade: true,
                in: installed.scope,
                connection: installed.connection,
                gate: AlwaysAllowGate()
            )
        }
        #expect(installed.pooled.executedQueries.isEmpty)
        let adapter = PluginDriverAdapter(connection: installed.connection, pluginDriver: TypeDropStubDriver())
        #expect(DatabaseObjectToolEligibility.Support.of(adapter).cascadingDropTypeKinds.isEmpty)
    }

    @Test("The adapter hands the driver the type it listed, schema and kind included")
    func adapterForwardsTheType() {
        let connection = TestFixtures.makeConnection(database: "shop", type: .cassandra)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: TypeDropStubDriver())

        #expect(adapter.generateDropTypeSQL(type: type, cascade: false) == "DROP TYPE shop.address")
        #expect(adapter.generateDropTypeSQL(type: UserDefinedTypeInfo(name: "p", kind: .composite, schema: "s"), cascade: false) == nil)
    }

    @Test("Support lists exactly the kinds the driver can drop")
    func supportReadsDroppableKinds() {
        let connection = TestFixtures.makeConnection(database: "shop", type: .cassandra)
        let adapter = PluginDriverAdapter(
            connection: connection,
            pluginDriver: TypeDropStubDriver(droppableKinds: [.udt, .enumeration])
        )

        #expect(DatabaseObjectToolEligibility.Support.of(adapter).droppableTypeKinds == [.udt, .enumeration])
        #expect(DatabaseObjectToolEligibility.Support.of(nil).droppableTypeKinds.isEmpty)
    }
}
