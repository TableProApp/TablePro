import Foundation
@testable import TablePro
import Testing

@Suite("Connection workspace registry")
@MainActor
struct ConnectionWorkspaceRegistryTests {
    private static let alpha = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")
    private static let beta = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")
    private static let gamma = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")

    private func makeWorkspace(_ connectionId: UUID) -> ConnectionWorkspace {
        ConnectionWorkspace(
            connectionId: connectionId,
            payload: nil,
            autoConnect: false,
            payloadConnection: nil,
            session: nil,
            sessionState: nil,
            rightPanelState: nil,
            phase: .idle
        )
    }

    @Test("Inserting selects the first workspace and keeps insertion order")
    func insertOrdersAndSelects() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let registry = ConnectionWorkspaceRegistry()

        registry.insert(makeWorkspace(alpha))
        registry.insert(makeWorkspace(beta))

        #expect(registry.connectionIds == [alpha, beta])
        #expect(registry.selectedConnectionId == beta)
        #expect(registry.count == 2)
    }

    @Test("Inserting a connection that is already hosted selects it instead of duplicating")
    func insertIsIdempotent() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let registry = ConnectionWorkspaceRegistry()
        let first = registry.insert(makeWorkspace(alpha))
        registry.insert(makeWorkspace(beta))

        let second = registry.insert(makeWorkspace(alpha))

        #expect(second === first)
        #expect(registry.connectionIds == [alpha, beta])
        #expect(registry.selectedConnectionId == alpha)
    }

    /// The reported sequence: open a second connection from a window that already has one, watch it
    /// fail, retry it. A failed attempt is a phase, not a departure, so the window stays on the
    /// connection throughout and can still be switched away from afterwards.
    @Test("A failed connection stays selected through its retry and can still be switched away from")
    func failedConnectionKeepsItsPlace() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let registry = ConnectionWorkspaceRegistry()
        registry.insert(makeWorkspace(alpha))
        let second = registry.insert(makeWorkspace(beta))

        second.phase = .unavailable(.failed(ConnectionFailureInfo(message: "refused")))
        #expect(registry.selectedConnectionId == beta)

        second.phase = .connecting
        second.phase = .connected
        #expect(registry.selectedConnectionId == beta)

        registry.select(alpha)
        #expect(registry.selectedConnectionId == alpha)
        registry.select(beta)
        #expect(registry.selectedConnectionId == beta)
    }

    /// The rail's entry list is rebuilt from this and its highlight from the selection, so a
    /// membership change has to announce itself even when the selection lands where it already was.
    @Test("Joining and leaving report membership separately from selection")
    func membershipAndSelectionAreSeparateSignals() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let registry = ConnectionWorkspaceRegistry()
        var memberships = 0
        var selections = 0
        registry.onMembershipChange = { memberships += 1 }
        registry.onSelectionChange = { _ in selections += 1 }

        registry.insert(makeWorkspace(alpha))
        registry.insert(makeWorkspace(beta))
        #expect(memberships == 2)
        #expect(selections == 2)

        registry.select(alpha)
        #expect(memberships == 2)
        #expect(selections == 3)

        registry.remove(beta)
        #expect(memberships == 3)
        #expect(selections == 3)
    }

    @Test("Each workspace keeps its own phase and attempt token")
    func workspacesAreIsolated() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let registry = ConnectionWorkspaceRegistry()
        let first = registry.insert(makeWorkspace(alpha))
        let second = registry.insert(makeWorkspace(beta))

        first.phase = .connected
        second.phase = .unavailable(.cancelled)
        first.attemptToken = UUID()

        #expect(registry.workspace(for: alpha)?.phase == .connected)
        #expect(registry.workspace(for: beta)?.phase == .unavailable(.cancelled))
        #expect(registry.workspace(for: beta)?.attemptToken == nil)
    }

    @Test("Each workspace owns a distinct undo manager")
    func undoManagersAreNotShared() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let registry = ConnectionWorkspaceRegistry()
        let first = registry.insert(makeWorkspace(alpha))
        let second = registry.insert(makeWorkspace(beta))

        #expect(first.undoManager !== second.undoManager)
    }

    @Test("Removing the selected workspace lands on its neighbour")
    func removeSelectsNeighbour() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let gamma = try #require(Self.gamma)
        let registry = ConnectionWorkspaceRegistry()
        registry.insert(makeWorkspace(alpha))
        registry.insert(makeWorkspace(beta))
        registry.insert(makeWorkspace(gamma))
        registry.select(beta)

        registry.remove(beta)

        #expect(registry.connectionIds == [alpha, gamma])
        #expect(registry.selectedConnectionId == gamma)
    }

    @Test("Removing the last workspace clears the selection")
    func removeLastClearsSelection() throws {
        let alpha = try #require(Self.alpha)
        let registry = ConnectionWorkspaceRegistry()
        registry.insert(makeWorkspace(alpha))

        registry.remove(alpha)

        #expect(registry.isEmpty)
        #expect(registry.selectedConnectionId == nil)
        #expect(registry.selected == nil)
    }

    @Test("Selecting a connection the registry does not host is ignored")
    func selectUnknownIsIgnored() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let registry = ConnectionWorkspaceRegistry()
        registry.insert(makeWorkspace(alpha))

        registry.select(beta)

        #expect(registry.selectedConnectionId == alpha)
    }

    @Test("A removed workspace is no longer reachable, so a late attempt finds nothing to write")
    func removedWorkspaceIsUnreachable() throws {
        let alpha = try #require(Self.alpha)
        let registry = ConnectionWorkspaceRegistry()
        registry.insert(makeWorkspace(alpha))

        registry.remove(alpha)

        #expect(registry.workspace(for: alpha) == nil)
        #expect(registry.contains(alpha) == false)
    }

    @Test("Cycling wraps in both directions")
    func cycleWraps() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let gamma = try #require(Self.gamma)
        let order = [alpha, beta, gamma]

        #expect(ConnectionWorkspaceRegistry.cycled(in: order, from: gamma, by: 1) == alpha)
        #expect(ConnectionWorkspaceRegistry.cycled(in: order, from: alpha, by: -1) == gamma)
        #expect(ConnectionWorkspaceRegistry.cycled(in: order, from: beta, by: 1) == gamma)
        #expect(ConnectionWorkspaceRegistry.cycled(in: [], from: alpha, by: 1) == nil)
        #expect(ConnectionWorkspaceRegistry.cycled(in: order, from: nil, by: 1) == alpha)
    }

    @Test("The neighbour of a removed row is the row that took its place")
    func neighbourResolution() throws {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)

        #expect(ConnectionWorkspaceRegistry.neighbour(in: [alpha, beta], removedIndex: 0) == alpha)
        #expect(ConnectionWorkspaceRegistry.neighbour(in: [alpha], removedIndex: 1) == alpha)
        #expect(ConnectionWorkspaceRegistry.neighbour(in: [], removedIndex: 0) == nil)
    }
}
