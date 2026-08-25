import Foundation
@testable import TablePro
import Testing

@Suite("Workspace rail ordering")
struct WorkspaceRailOrderingTests {
    private static let alpha = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")
    private static let beta = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")
    private static let gamma = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")
    private static let delta = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")

    private func ids() throws -> (WorkspaceID, WorkspaceID, WorkspaceID, WorkspaceID) {
        let alpha = try #require(Self.alpha)
        let beta = try #require(Self.beta)
        let gamma = try #require(Self.gamma)
        let delta = try #require(Self.delta)
        return (
            WorkspaceID(connectionId: alpha, container: "app"),
            WorkspaceID(connectionId: beta, container: "app"),
            WorkspaceID(connectionId: gamma, container: "app"),
            WorkspaceID(connectionId: delta, container: "app")
        )
    }

    @Test("Stored order is preserved for connections that are still open")
    func storedOrderWins() throws {
        let (alpha, beta, gamma, _) = try ids()
        let ranked = WorkspaceRailOrdering.ranked(
            openIds: [alpha, beta, gamma],
            storedOrder: [gamma, alpha, beta],
            openedAt: [:]
        )
        #expect(ranked == [gamma, alpha, beta])
    }

    @Test("A connection that is no longer open drops out without losing its slot in storage")
    func closedConnectionIsFilteredNotForgotten() throws {
        let (alpha, beta, gamma, _) = try ids()
        let ranked = WorkspaceRailOrdering.ranked(
            openIds: [alpha, gamma],
            storedOrder: [alpha, beta, gamma],
            openedAt: [:]
        )
        #expect(ranked == [alpha, gamma])

        let merged = WorkspaceRailOrdering.merged(
            visibleOrder: [gamma, alpha],
            into: [alpha, beta, gamma]
        )
        #expect(merged == [gamma, beta, alpha])
    }

    @Test("New connections append in the order they connected, never at the front")
    func newcomersAppendByConnectionTime() throws {
        let (alpha, beta, gamma, _) = try ids()
        let base = Date(timeIntervalSince1970: 1_000)
        let ranked = WorkspaceRailOrdering.ranked(
            openIds: [alpha, beta, gamma],
            storedOrder: [gamma],
            openedAt: [
                alpha.connectionId: base.addingTimeInterval(20),
                beta.connectionId: base.addingTimeInterval(10),
            ]
        )
        #expect(ranked == [gamma, beta, alpha])
    }

    @Test("A connection that has no session yet sorts last, not first")
    func sessionlessNewcomerSortsLast() throws {
        let (alpha, beta, gamma, _) = try ids()
        let base = Date(timeIntervalSince1970: 1_000)
        let ranked = WorkspaceRailOrdering.ranked(
            openIds: [alpha, beta, gamma],
            storedOrder: [],
            openedAt: [alpha.connectionId: base, beta.connectionId: base.addingTimeInterval(10)]
        )
        #expect(ranked == [alpha, beta, gamma])
    }

    @Test("Simultaneous connections break ties deterministically")
    func simultaneousConnectionsAreStable() throws {
        let (alpha, beta, _, _) = try ids()
        let sameMoment = Date(timeIntervalSince1970: 500)
        let first = WorkspaceRailOrdering.ranked(
            openIds: [alpha, beta],
            storedOrder: [],
            openedAt: [alpha.connectionId: sameMoment, beta.connectionId: sameMoment]
        )
        let second = WorkspaceRailOrdering.ranked(
            openIds: [beta, alpha],
            storedOrder: [],
            openedAt: [alpha.connectionId: sameMoment, beta.connectionId: sameMoment]
        )
        #expect(first == second)
    }

    @Test("Dragging a row down lands it after the row it was dropped past")
    func reorderMovingDown() throws {
        let (alpha, beta, gamma, _) = try ids()
        let reordered = WorkspaceRailOrdering.reordered([alpha, beta, gamma], moving: alpha, toRow: 2)
        #expect(reordered == [beta, alpha, gamma])
    }

    @Test("Dragging a row to the end places it last")
    func reorderToEnd() throws {
        let (alpha, beta, gamma, _) = try ids()
        let reordered = WorkspaceRailOrdering.reordered([alpha, beta, gamma], moving: alpha, toRow: 3)
        #expect(reordered == [beta, gamma, alpha])
    }

    @Test("Dragging a row up inserts it before the drop target")
    func reorderMovingUp() throws {
        let (alpha, beta, gamma, _) = try ids()
        let reordered = WorkspaceRailOrdering.reordered([alpha, beta, gamma], moving: gamma, toRow: 0)
        #expect(reordered == [gamma, alpha, beta])
    }

    @Test("Dropping a row onto itself changes nothing")
    func reorderOntoSelfIsNoOp() throws {
        let (alpha, beta, gamma, _) = try ids()
        let reordered = WorkspaceRailOrdering.reordered([alpha, beta, gamma], moving: beta, toRow: 1)
        #expect(reordered == [alpha, beta, gamma])
    }

    @Test("Reordering an id that is not in the list is ignored")
    func reorderUnknownIdIsIgnored() throws {
        let (alpha, beta, gamma, delta) = try ids()
        let reordered = WorkspaceRailOrdering.reordered([alpha, beta, gamma], moving: delta, toRow: 0)
        #expect(reordered == [alpha, beta, gamma])
    }

    @Test("Cycling follows the order shown, not the order connections were opened")
    func cyclingFollowsVisualOrder() throws {
        let (alpha, beta, gamma, _) = try ids()
        let visual = [gamma, alpha, beta]
        #expect(WorkspaceRailOrdering.cycled(in: visual, from: gamma, by: 1) == alpha)
        #expect(WorkspaceRailOrdering.cycled(in: visual, from: alpha, by: 1) == beta)
        #expect(WorkspaceRailOrdering.cycled(in: visual, from: beta, by: -1) == alpha)
    }

    @Test("Cycling wraps around at both ends")
    func cyclingWraps() throws {
        let (alpha, beta, gamma, _) = try ids()
        let visual = [alpha, beta, gamma]
        #expect(WorkspaceRailOrdering.cycled(in: visual, from: gamma, by: 1) == alpha)
        #expect(WorkspaceRailOrdering.cycled(in: visual, from: alpha, by: -1) == gamma)
    }

    @Test("Cycling an empty rail yields nothing")
    func cyclingEmptyRail() {
        #expect(WorkspaceRailOrdering.cycled(in: [], from: nil, by: 1) == nil)
    }

    @Test("Cycling from an unknown connection starts at the first entry")
    func cyclingFromUnknownStartsAtFirst() throws {
        let (alpha, beta, _, delta) = try ids()
        #expect(WorkspaceRailOrdering.cycled(in: [alpha, beta], from: delta, by: 1) == alpha)
    }

    @Test("Merging a reorder appends visible ids that storage had never seen")
    func mergeAppendsUnknownVisibleIds() throws {
        let (alpha, beta, gamma, _) = try ids()
        let merged = WorkspaceRailOrdering.merged(visibleOrder: [beta, gamma], into: [alpha, beta])
        #expect(merged == [alpha, beta, gamma])
    }

    @Test("One connection's databases stay together, ordered by name")
    func containersOfOneConnectionGroupTogether() throws {
        let (alpha, beta, _, _) = try ids()
        let base = Date(timeIntervalSince1970: 1_000)
        let logs = WorkspaceID(connectionId: alpha.connectionId, container: "logs")
        let archive = WorkspaceID(connectionId: alpha.connectionId, container: "archive")

        let ranked = WorkspaceRailOrdering.ranked(
            openIds: [alpha, beta, logs, archive],
            storedOrder: [],
            openedAt: [
                alpha.connectionId: base,
                beta.connectionId: base.addingTimeInterval(10),
            ]
        )
        #expect(ranked == [alpha, archive, logs, beta])
    }

    @Test("Two databases of one connection are ordered by name, not by hash")
    func containerOrderIsStable() throws {
        let (alpha, _, _, _) = try ids()
        let logs = WorkspaceID(connectionId: alpha.connectionId, container: "logs")
        let first = WorkspaceRailOrdering.ranked(openIds: [alpha, logs], storedOrder: [], openedAt: [:])
        let second = WorkspaceRailOrdering.ranked(openIds: [logs, alpha], storedOrder: [], openedAt: [:])
        #expect(first == [alpha, logs])
        #expect(first == second)
    }

    /// The cap exists because a database that is renamed or dropped raises no event, so its entry
    /// can never be removed the way a deleted connection's is. Everything open survives it.
    @Test("The cap never drops a workspace that is open")
    func capKeepsEveryVisibleEntry() {
        let connectionId = UUID()
        let visible = (0..<10).map { WorkspaceID(connectionId: connectionId, container: "open\($0)") }
        let closed = (0..<WorkspaceRailOrdering.maxStoredEntries).map {
            WorkspaceID(connectionId: connectionId, container: "closed\($0)")
        }

        let capped = WorkspaceRailOrdering.capped(closed + visible, keeping: Set(visible))

        #expect(capped.count == WorkspaceRailOrdering.maxStoredEntries)
        #expect(visible.allSatisfy(capped.contains))
    }

    /// Trimming the list itself would take the newest arrangements: `merged` appends what it has
    /// just seen at the end, so the oldest closed entries are the ones at the front.
    @Test("The cap drops closed entries oldest first")
    func capDropsTheOldestClosedEntries() {
        let connectionId = UUID()
        let stored = (0..<(WorkspaceRailOrdering.maxStoredEntries + 2)).map {
            WorkspaceID(connectionId: connectionId, container: "closed\($0)")
        }

        let capped = WorkspaceRailOrdering.capped(stored, keeping: [])

        #expect(capped.count == WorkspaceRailOrdering.maxStoredEntries)
        #expect(capped.first == stored[2])
        #expect(capped.last == stored.last)
    }

    @Test("A list within budget is left exactly as it is")
    func capIsInertWithinBudget() {
        let connectionId = UUID()
        let stored = (0..<3).map { WorkspaceID(connectionId: connectionId, container: "c\($0)") }
        #expect(WorkspaceRailOrdering.capped(stored, keeping: []) == stored)
    }
}
