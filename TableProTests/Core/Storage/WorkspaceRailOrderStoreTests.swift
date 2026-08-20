import Combine
import Foundation
@testable import TablePro
import Testing

@Suite("Workspace rail order store")
@MainActor
struct WorkspaceRailOrderStoreTests {
    private func makeId(container: String = "app") -> WorkspaceID {
        WorkspaceID(connectionId: UUID(), container: container)
    }

    private func makeStore() throws -> (WorkspaceRailOrderStore, UserDefaults, String) {
        let suiteName = "com.TablePro.tests.workspaceRail.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (WorkspaceRailOrderStore(defaults: defaults), defaults, suiteName)
    }

    @Test("A fresh store has no stored arrangement")
    func emptyByDefault() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(store.order.isEmpty)
    }

    @Test("An arrangement round-trips through UserDefaults")
    func orderRoundTrips() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ids = [makeId(), makeId(), makeId()]
        store.setOrder(ids)
        #expect(store.order == ids)

        let reloaded = WorkspaceRailOrderStore(defaults: defaults)
        #expect(reloaded.order == ids)
    }

    @Test("Applying a visible order keeps closed connections in their slot")
    func visibleOrderKeepsClosedConnections() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let alpha = makeId()
        let closed = makeId()
        let gamma = makeId()
        store.setOrder([alpha, closed, gamma])

        store.applyVisibleOrder([gamma, alpha])
        #expect(store.order == [gamma, closed, alpha])
    }

    @Test("A reorder is published once so every other window's rail reloads")
    func reorderIsPublishedOnce() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var events = 0
        let subscription = AppEvents.shared.workspaceRailOrderChanged.sink { events += 1 }
        defer { subscription.cancel() }

        let ids = [makeId(), makeId()]
        store.setOrder(ids)
        #expect(events == 1)

        let written = defaults.data(forKey: PreferenceKeys.workspaceRailOrder.name)
        store.setOrder(ids)

        #expect(events == 1)
        #expect(defaults.data(forKey: PreferenceKeys.workspaceRailOrder.name) == written)
        #expect(store.order == ids)
    }

    @Test("Two databases of one connection keep separate slots")
    func containersOfOneConnectionAreDistinct() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let connectionId = UUID()
        let app = WorkspaceID(connectionId: connectionId, container: "app")
        let logs = WorkspaceID(connectionId: connectionId, container: "logs")
        store.setOrder([logs, app])

        #expect(WorkspaceRailOrderStore(defaults: defaults).order == [logs, app])
    }
}
