import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@testable import TablePro  // for TestFixtures if needed, but assume it's in test target

@Suite("WorkspaceContext")
struct WorkspaceContextTests {
    @Test("PostgreSQL contexts include database and schema")
    func schemaAwareContext() {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let key = WorkspaceContextKey.resolve(
            connection: connection,
            databaseName: "app",
            schemaName: "audit",
            activeDatabase: "ignored",
            activeSchema: "public",
            supportsSchemaSwitching: true
        )
        #expect(key.connectionId == connection.id)
        #expect(key.databaseName == "app")
        #expect(key.schemaName == "audit")
    }

    @Test("Engines without schema switching normalize schema to nil")
    func schemaBlindContext() {
        let connection = TestFixtures.makeConnection(database: "app", type: .mysql)
        let key = WorkspaceContextKey.resolve(
            connection: connection,
            databaseName: nil,
            schemaName: "ignored",
            activeDatabase: nil,
            activeSchema: "ignored",
            supportsSchemaSwitching: false
        )
        #expect(key.databaseName == "app")
        #expect(key.schemaName == nil)
    }

    @Test("Identifiers cannot collide when names contain separators")
    func collisionSafeIdentifier() {
        let connectionId = UUID()
        let first = WorkspaceContextKey(connectionId: connectionId, databaseName: "a.b", schemaName: "c")
        let second = WorkspaceContextKey(connectionId: connectionId, databaseName: "a", schemaName: "b.c")
        #expect(first.tabbingIdentifier != second.tabbingIdentifier)
    }

    @Test("Explicit names win over live and configured fallbacks")
    func precedence() {
        let connection = TestFixtures.makeConnection(database: "configured")
        let key = WorkspaceContextKey.resolve(
            connection: connection,
            databaseName: "payload",
            schemaName: nil,
            activeDatabase: "live",
            activeSchema: nil,
            supportsSchemaSwitching: false
        )
        #expect(key.databaseName == "payload")
    }
}

@MainActor
@Suite("WorkspaceContextRegistry")
struct WorkspaceContextRegistryTests {
    @Test("A second window for the same key does not add another rail item")
    func registerDeduplicatesByKey() {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let item = contextDescriptor(database: "app", schema: "public")
        let firstWindow = UUID()
        let secondWindow = UUID()

        registry.register(windowId: firstWindow, descriptor: item)
        registry.register(windowId: secondWindow, descriptor: item)

        #expect(registry.contexts.map(\.key) == [item.key])
        #expect(registry.windowIds(for: item.key) == [firstWindow, secondWindow])
    }

    @Test("Registering the same key keeps first-open order")
    func registerPreservesFirstOpenOrder() {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let first = contextDescriptor(database: "app", schema: "public")
        let second = contextDescriptor(database: "app", schema: "audit")

        registry.register(windowId: UUID(), descriptor: first)
        registry.register(windowId: UUID(), descriptor: second)
        registry.register(windowId: UUID(), descriptor: first)

        #expect(registry.contexts.map(\.key) == [first.key, second.key])
    }

    @Test("The last window for a key removes that rail item")
    func unregisterLastWindowRemovesDescriptor() {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let item = contextDescriptor(database: "app", schema: "public")
        let firstWindow = UUID()
        let secondWindow = UUID()

        registry.register(windowId: firstWindow, descriptor: item)
        registry.register(windowId: secondWindow, descriptor: item)
        registry.unregister(windowId: firstWindow)

        #expect(registry.contexts.map(\.key) == [item.key])
        #expect(registry.windowIds(for: item.key) == [secondWindow])

        registry.unregister(windowId: secondWindow)

        #expect(registry.contexts.isEmpty)
        #expect(registry.windowIds(for: item.key).isEmpty)
        #expect(!registry.contains(item.key))
    }

    @Test("unregisterAll removes every window and the rail item")
    func unregisterAllRemovesContext() {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let item = contextDescriptor(database: "app", schema: "public")
        registry.register(windowId: UUID(), descriptor: item)
        registry.register(windowId: UUID(), descriptor: item)

        registry.unregisterAll(for: item.key)

        #expect(registry.contexts.isEmpty)
        #expect(registry.windowIds(for: item.key).isEmpty)
        #expect(!registry.contains(item.key))
    }

    @Test("Removing the selected context selects the most recently used remainder")
    func removingSelectedContextSelectsMRU() throws {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let first = contextDescriptor(database: "app", schema: "public")
        let second = contextDescriptor(database: "app", schema: "audit")
        let firstWindow = UUID()
        let secondWindow = UUID()

        registry.register(windowId: firstWindow, descriptor: first)
        registry.register(windowId: secondWindow, descriptor: second)

        let firstRequest = try #require(registry.beginActivation(for: first.key))
        #expect(registry.commitActivation(first.key, request: firstRequest))
        let secondRequest = try #require(registry.beginActivation(for: second.key))
        #expect(registry.commitActivation(second.key, request: secondRequest))

        registry.unregister(windowId: secondWindow)

        #expect(registry.selectedKey == first.key)
        #expect(registry.contexts.map(\.key) == [first.key])
    }

    @Test("A stale activation request cannot replace the latest selection")
    func staleActivationIsIgnored() throws {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let first = contextDescriptor(database: "app", schema: "public")
        let second = contextDescriptor(database: "app", schema: "audit")
        registry.register(windowId: UUID(), descriptor: first)
        registry.register(windowId: UUID(), descriptor: second)

        let stale = try #require(registry.beginActivation(for: first.key))
        let latest = try #require(registry.beginActivation(for: second.key))

        #expect(!registry.commitActivation(first.key, request: stale))
        #expect(registry.commitActivation(second.key, request: latest))
        #expect(registry.selectedKey == second.key)
    }

    @Test("Persisted order is the unique first-open key list")
    func persistWritesDeduplicatedKeys() {
        let store = InMemoryWorkspaceContextSnapshotStore()
        let registry = WorkspaceContextRegistry(store: store)
        let item = contextDescriptor(database: "app", schema: "public")

        registry.register(windowId: UUID(), descriptor: item)
        registry.register(windowId: UUID(), descriptor: item)

        #expect(store.snapshot.orderedKeys == [item.key])
    }

    @Test("Snapshot keys are not shown until a window registers")
    func snapshotDoesNotFabricateRailRows() {
        let first = contextDescriptor(database: "app", schema: "public")
        let second = contextDescriptor(database: "app", schema: "audit")
        let store = InMemoryWorkspaceContextSnapshotStore()
        store.snapshot = WorkspaceContextSnapshot(
            orderedKeys: [second.key, first.key],
            selectedKey: first.key
        )

        let registry = WorkspaceContextRegistry(store: store)

        #expect(registry.contexts.isEmpty)
        #expect(registry.selectedKey == first.key)

        registry.register(windowId: UUID(), descriptor: first)
        registry.register(windowId: UUID(), descriptor: second)

        #expect(registry.contexts.map(\.key) == [second.key, first.key])
    }

    @Test("Driver capability decides whether schema is part of the key")
    func resolveUsesDriverSchemaCapability() {
        let mysql = TestFixtures.makeConnection(database: "app", type: .mysql)
        let mysqlKey = WorkspaceContextResolver.resolve(
            connection: mysql,
            databaseName: "app",
            schemaName: "ignored"
        )
        #expect(mysqlKey.schemaName == nil)

        let postgres = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let postgresKey = WorkspaceContextResolver.resolve(
            connection: postgres,
            databaseName: "app",
            schemaName: "audit"
        )
        #expect(postgresKey.schemaName == "audit")
    }
}

@MainActor
@Suite("WorkspaceContextCloseCoordinator")
struct WorkspaceContextCloseCoordinatorTests {
    @Test("A later cancel does not close an earlier window that already passed preflight")
    func laterCancelLeavesEveryWindowRegistered() async {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let item = contextDescriptor(database: "app", schema: "public")
        let firstWindow = UUID()
        let secondWindow = UUID()
        registry.register(windowId: firstWindow, descriptor: item)
        registry.register(windowId: secondWindow, descriptor: item)

        var confirmed: [UUID] = []
        var closed: [UUID] = []
        let coordinator = WorkspaceContextCloseCoordinator(
            registry: registry,
            confirmWindow: { windowId in
                confirmed.append(windowId)
                return windowId != secondWindow
            },
            closeWindow: { windowId in
                closed.append(windowId)
            },
            activate: { _ in }
        )

        let didClose = await coordinator.close(key: item.key, sourceWindow: nil)

        #expect(!didClose)
        #expect(confirmed == [firstWindow, secondWindow])
        #expect(closed.isEmpty)
        #expect(registry.contains(item.key))
        #expect(registry.windowIds(for: item.key) == [firstWindow, secondWindow])
    }

    @Test("A running query without unsaved work blocks context close")
    func runningQueryCancelLeavesContextIntact() async {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        defer { state.coordinator.teardown() }

        let windowId = UUID()
        state.coordinator.windowId = windowId
        state.coordinator.toolbarState.setExecuting(true)

        let item = contextDescriptor(database: "app", schema: "public")
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        registry.register(windowId: windowId, descriptor: item)

        let coordinator = WorkspaceContextCloseCoordinator(
            registry: registry,
            activate: { _ in }
        )

        let didClose = await coordinator.close(key: item.key, sourceWindow: nil)

        #expect(!didClose)
        #expect(registry.contains(item.key))
        #expect(registry.windowIds(for: item.key) == [windowId])
    }

    @Test("A successful close unregisters every window and the rail item")
    func successfulCloseRemovesContext() async throws {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let first = contextDescriptor(database: "app", schema: "public")
        let second = contextDescriptor(database: "app", schema: "audit")
        let firstWindow = UUID()
        let remainingWindow = UUID()
        registry.register(windowId: firstWindow, descriptor: first)
        registry.register(windowId: remainingWindow, descriptor: second)

        let firstRequest = try #require(registry.beginActivation(for: first.key))
        #expect(registry.commitActivation(first.key, request: firstRequest))
        let secondRequest = try #require(registry.beginActivation(for: second.key))
        #expect(registry.commitActivation(second.key, request: secondRequest))

        var confirmed: [UUID] = []
        var closed: [UUID] = []
        var activated: [WorkspaceContextKey] = []
        let coordinator = WorkspaceContextCloseCoordinator(
            registry: registry,
            confirmWindow: { windowId in
                confirmed.append(windowId)
                return true
            },
            closeWindow: { windowId in
                closed.append(windowId)
            },
            activate: { activated.append($0) }
        )

        let didClose = await coordinator.close(key: second.key, sourceWindow: nil)

        #expect(didClose)
        #expect(confirmed == [remainingWindow])
        #expect(closed == [remainingWindow])
        #expect(!registry.contains(second.key))
        #expect(registry.contains(first.key))
        #expect(registry.selectedKey == first.key)
        #expect(activated == [first.key])
    }

    @Test("Unsaved work without a prompt still blocks context close")
    func unsavedWorkBlocksCloseWhenPromptUnavailable() async {
        let connection = TestFixtures.makeConnection(database: "app", type: .postgresql)
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        defer { state.coordinator.teardown() }

        let windowId = UUID()
        state.coordinator.windowId = windowId
        state.coordinator.changeManager.hasChanges = true

        let item = contextDescriptor(database: "app", schema: "public")
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        registry.register(windowId: windowId, descriptor: item)

        let coordinator = WorkspaceContextCloseCoordinator(
            registry: registry,
            activate: { _ in }
        )

        let didClose = await coordinator.close(key: item.key, sourceWindow: nil)

        #expect(!didClose)
        #expect(registry.contains(item.key))
        #expect(registry.windowIds(for: item.key) == [windowId])
    }

    @Test("Activation and close share the registry they were given")
    func coordinatorsShareInjectedRegistry() {
        let registry = WorkspaceContextRegistry(store: InMemoryWorkspaceContextSnapshotStore())
        let item = contextDescriptor(database: "app", schema: "public")
        registry.register(windowId: UUID(), descriptor: item)

        let activation = WorkspaceContextActivationCoordinator(registry: registry)
        activation.activate(item.key)

        #expect(registry.selectedKey == item.key)
    }
}

private func contextDescriptor(database: String, schema: String?) -> WorkspaceContextDescriptor {
    let connection = TestFixtures.makeConnection(database: database, type: .postgresql)
    let key = WorkspaceContextKey.resolve(
        connection: connection,
        databaseName: database,
        schemaName: schema,
        activeDatabase: nil,
        activeSchema: nil,
        supportsSchemaSwitching: true
    )
    return WorkspaceContextDescriptor(
        key: key,
        connectionName: connection.name,
        databaseType: connection.type,
        connectionColor: .blue,
        isConnected: true
    )
}

private final class InMemoryWorkspaceContextSnapshotStore: WorkspaceContextSnapshotStoring {
    var snapshot = WorkspaceContextSnapshot(orderedKeys: [], selectedKey: nil)

    func load() -> WorkspaceContextSnapshot {
        snapshot
    }

    func save(_ snapshot: WorkspaceContextSnapshot) {
        self.snapshot = snapshot
    }
}
