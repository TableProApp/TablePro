import Foundation
@testable import TableProMobile
import Testing
import UIKit

@MainActor
private final class SpyLiveActivityHandle: LiveActivityHandle {
    let id: String
    private(set) var state: QueryActivityAttributes.ContentState
    private(set) var endedStates: [QueryActivityAttributes.ContentState] = []
    private(set) var updatedStaleDates: [Date?] = []
    weak var store: SpyLiveActivityStore?
    var holdsEndUntilReleased = false
    private(set) var isEndParked = false
    private var endGate: CheckedContinuation<Void, Never>?

    init(id: String, state: QueryActivityAttributes.ContentState) {
        self.id = id
        self.state = state
    }

    func update(state: QueryActivityAttributes.ContentState, staleDate: Date?) async {
        self.state = state
        updatedStaleDates.append(staleDate)
    }

    func end(state: QueryActivityAttributes.ContentState) async {
        if holdsEndUntilReleased {
            await withCheckedContinuation {
                endGate = $0
                isEndParked = true
            }
        }
        self.state = state
        endedStates.append(state)
        store?.forget(self)
    }

    func releaseEnd() {
        isEndParked = false
        endGate?.resume()
        endGate = nil
    }
}

@MainActor
private final class SpyLiveActivityStore: LiveActivityStore {
    var areActivitiesEnabled = true
    var existing: [SpyLiveActivityHandle] = []
    var requested: [SpyLiveActivityHandle] = []
    var requestError: (any Error)?
    private var nextId = 0

    var liveActivities: [any LiveActivityHandle] { existing }

    func adopt(_ handles: [SpyLiveActivityHandle]) {
        for handle in handles {
            handle.store = self
        }
        existing = handles
    }

    func forget(_ handle: SpyLiveActivityHandle) {
        existing.removeAll { $0 === handle }
    }

    func request(
        attributes: QueryActivityAttributes,
        state: QueryActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> any LiveActivityHandle {
        if let requestError {
            throw requestError
        }
        nextId += 1
        let handle = SpyLiveActivityHandle(id: "new-\(nextId)", state: state)
        handle.store = self
        requested.append(handle)
        existing.append(handle)
        return handle
    }
}

@MainActor
private final class SpyAsserter: BackgroundTaskAsserting {
    private(set) var beginCount = 0
    private(set) var endCount = 0

    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        beginCount += 1
        return UIBackgroundTaskIdentifier(rawValue: 11)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        endCount += 1
    }
}

private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

@MainActor
private func makeController(
    store: SpyLiveActivityStore,
    asserter: SpyAsserter = SpyAsserter()
) -> QueryActivityController {
    QueryActivityController(store: store, asserter: asserter, now: { referenceNow })
}

@MainActor
@Suite(.serialized)
struct QueryActivityControllerTests {
    @Test
    func reapEndsEveryActivityLeftByAPreviousProcess() async {
        let store = SpyLiveActivityStore()
        let orphan = SpyLiveActivityHandle(
            id: "orphan",
            state: .init(startedAt: referenceNow.addingTimeInterval(-90))
        )
        store.adopt([orphan])
        let controller = makeController(store: store)

        await controller.reapOrphans()
        _ = await controller.start(
            connectionId: UUID(),
            connectionName: "SIT",
            query: "select * FROM User",
            startedAt: referenceNow
        )

        #expect(orphan.endedStates.count == 1)
        #expect(orphan.endedStates.first?.outcome == .interrupted)
        #expect(orphan.endedStates.first?.endedAt == referenceNow)
    }

    @Test
    func reapPreservesTheElapsedTimeTheOrphanRecorded() async {
        let store = SpyLiveActivityStore()
        let startedAt = referenceNow.addingTimeInterval(-136)
        let orphan = SpyLiveActivityHandle(
            id: "orphan",
            state: .init(startedAt: startedAt, rowsStreamed: 42)
        )
        store.adopt([orphan])
        let controller = makeController(store: store)

        await controller.reapOrphans()
        _ = await controller.start(
            connectionId: UUID(),
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )

        let final = orphan.endedStates.first
        #expect(final?.startedAt == startedAt)
        #expect(final?.rowsStreamed == 42)
    }

    @Test
    func reapNeverEndsAnActivityThisProcessOwns() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)
        let connectionId = UUID()

        _ = await controller.start(
            connectionId: connectionId,
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )
        let owned = store.requested.first
        await controller.reapOrphans()

        #expect(owned?.endedStates.isEmpty == true)
        #expect(controller.ownedActivityIds.count == 1)
    }

    @Test
    func aSecondConnectionsActivitySurvivesAReapWhileBothRun() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)

        _ = await controller.start(
            connectionId: UUID(),
            connectionName: "First",
            query: "select 1",
            startedAt: referenceNow
        )
        _ = await controller.start(
            connectionId: UUID(),
            connectionName: "Second",
            query: "select 2",
            startedAt: referenceNow
        )
        await controller.reapOrphans()

        #expect(store.requested.count == 2)
        #expect(store.requested.allSatisfy { $0.endedStates.isEmpty })
    }

    @Test
    func twoScenesOnOneConnectionKeepSeparateActivities() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)
        let shared = UUID()

        let first = await controller.start(
            connectionId: shared,
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )
        let second = await controller.start(
            connectionId: shared,
            connectionName: "SIT",
            query: "select 2",
            startedAt: referenceNow
        )

        #expect(first != second)
        #expect(store.requested.count == 2)
        #expect(store.requested.allSatisfy { $0.endedStates.isEmpty })

        await controller.end(token: second, outcome: .completed)

        #expect(store.requested.first?.endedStates.isEmpty == true)
        #expect(controller.ownedActivityIds.count == 1)
    }

    @Test
    func endingOneSceneLeavesTheOtherSceneUpdatable() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)
        let shared = UUID()

        let first = await controller.start(
            connectionId: shared,
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )
        let second = await controller.start(
            connectionId: shared,
            connectionName: "SIT",
            query: "select 2",
            startedAt: referenceNow
        )
        await controller.end(token: second, outcome: .completed)
        await controller.update(token: first, rowsStreamed: 5)

        #expect(store.requested.first?.state.rowsStreamed == 5)
    }

    @Test
    func suspensionEndsEveryActivityOnThatConnectionOnly() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)
        let doomed = UUID()
        let survivor = UUID()

        _ = await controller.start(
            connectionId: doomed,
            connectionName: "DuckDB",
            query: "select 1",
            startedAt: referenceNow
        )
        _ = await controller.start(
            connectionId: survivor,
            connectionName: "SIT",
            query: "select 2",
            startedAt: referenceNow
        )

        await controller.endEverything(forConnection: doomed, outcome: .interrupted)

        #expect(store.requested[0].endedStates.first?.outcome == .interrupted)
        #expect(store.requested[1].endedStates.isEmpty)
    }

    @Test
    func aLongQueryWithNoNewRowsStillRefreshesItsStaleDate() async {
        let store = SpyLiveActivityStore()
        var clock = referenceNow
        let controller = QueryActivityController(
            store: store,
            asserter: SpyAsserter(),
            now: { clock }
        )
        let token = await controller.start(
            connectionId: UUID(),
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )

        clock = referenceNow.addingTimeInterval(QueryActivityStaleWindow.seconds / 2 + 1)
        await controller.update(token: token, rowsStreamed: 0)

        let handle = store.requested.first
        #expect(handle?.updatedStaleDates.count == 1)
        #expect(handle?.state.lastUpdatedAt == clock)
    }

    @Test
    func endRecordsTheOutcomeTheQueryActuallyReached() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)
        let connectionId = UUID()

        let token = await controller.start(
            connectionId: connectionId,
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )
        await controller.end(token: token, outcome: .stopped)

        let final = store.requested.first?.endedStates.first
        #expect(final?.outcome == .stopped)
        #expect(final?.endedAt == referenceNow)
    }

    @Test
    func aReapDuringAnInFlightEndDoesNotEndTheActivityTwice() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)

        let token = await controller.start(
            connectionId: UUID(),
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )
        let handle = store.requested.first
        handle?.holdsEndUntilReleased = true

        let ending = Task { await controller.end(token: token, outcome: .completed) }
        while handle?.isEndParked == false {
            await Task.yield()
        }
        await controller.reapOrphans()
        handle?.releaseEnd()
        await ending.value

        #expect(handle?.endedStates.count == 1)
        #expect(handle?.endedStates.first?.outcome == .completed)
        #expect(controller.ownedActivityIds.isEmpty)
    }

    @Test
    func endHoldsABackgroundAssertionForTheWholeCall() async {
        let store = SpyLiveActivityStore()
        let asserter = SpyAsserter()
        let controller = makeController(store: store, asserter: asserter)
        let connectionId = UUID()

        let token = await controller.start(
            connectionId: connectionId,
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )
        await controller.end(token: token, outcome: .completed)

        #expect(asserter.beginCount >= 1)
        #expect(asserter.endCount == asserter.beginCount)
    }

    @Test
    func theStaleDateSlidesForwardWithEveryProgressUpdate() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)
        let connectionId = UUID()
        let startedAt = referenceNow.addingTimeInterval(-240)

        let token = await controller.start(
            connectionId: connectionId,
            connectionName: "SIT",
            query: "select 1",
            startedAt: startedAt
        )
        await controller.update(token: token, rowsStreamed: 500)

        let slid = store.requested.first?.updatedStaleDates.first ?? nil
        #expect(slid == referenceNow.addingTimeInterval(QueryActivityStaleWindow.seconds))
    }

    @Test
    func aRepeatedRowCountSendsNoUpdate() async {
        let store = SpyLiveActivityStore()
        let controller = makeController(store: store)
        let connectionId = UUID()

        let token = await controller.start(
            connectionId: connectionId,
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )
        await controller.update(token: token, rowsStreamed: 12)
        await controller.update(token: token, rowsStreamed: 12)

        #expect(store.requested.first?.updatedStaleDates.count == 1)
    }

    @Test
    func aFailedRequestLeavesNothingOwnedSoTheNextReapIsUnaffected() async {
        let store = SpyLiveActivityStore()
        store.requestError = CocoaError(.fileNoSuchFile)
        let controller = makeController(store: store)
        let connectionId = UUID()

        let token = await controller.start(
            connectionId: connectionId,
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )

        #expect(token == nil)
        #expect(controller.ownedActivityIds.isEmpty)
    }

    @Test
    func nothingIsRequestedWhileLiveActivitiesAreTurnedOff() async {
        let store = SpyLiveActivityStore()
        store.areActivitiesEnabled = false
        let controller = makeController(store: store)

        _ = await controller.start(
            connectionId: UUID(),
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )

        #expect(store.requested.isEmpty)
    }

    @Test
    func aDisabledStoreStillReapsWhatAnEarlierProcessLeftBehind() async {
        let store = SpyLiveActivityStore()
        store.areActivitiesEnabled = false
        let orphan = SpyLiveActivityHandle(id: "orphan", state: .init(startedAt: referenceNow))
        store.adopt([orphan])
        let controller = makeController(store: store)

        _ = await controller.start(
            connectionId: UUID(),
            connectionName: "SIT",
            query: "select 1",
            startedAt: referenceNow
        )

        #expect(orphan.endedStates.count == 1)
    }
}

@Suite
struct QueryActivityContentStateDecodingTests {
    @Test
    func aStateEncodedBeforeTheOutcomeFieldExistedStillDecodes() throws {
        let legacy = #"{"startedAt": 757400000, "rowsStreamed": 7}"#
        let data = try #require(legacy.data(using: .utf8))

        let state = try JSONDecoder().decode(QueryActivityAttributes.ContentState.self, from: data)

        #expect(state.outcome == .running)
        #expect(state.rowsStreamed == 7)
        #expect(state.endedAt == nil)
    }

    @Test
    func aLegacyEndedStateDecodesAsCompletedRatherThanRunning() throws {
        let legacy = #"{"startedAt": 757400000, "endedAt": 757400012, "rowsStreamed": 3}"#
        let data = try #require(legacy.data(using: .utf8))

        let state = try JSONDecoder().decode(QueryActivityAttributes.ContentState.self, from: data)

        #expect(state.outcome == .completed)
    }

    @Test
    func aStaleCardReportsTheElapsedTimeItLastReachedNotTheStaleWindow() {
        let startedAt = referenceNow.addingTimeInterval(-900)
        let state = QueryActivityAttributes.ContentState(
            startedAt: startedAt,
            lastUpdatedAt: referenceNow.addingTimeInterval(-300)
        )

        #expect(state.elapsedWhenLastAlive == 600)
    }

    @Test
    func aLegacyStateReportsNoElapsedTimeRatherThanANegativeOne() throws {
        let legacy = #"{"startedAt": 757400000, "rowsStreamed": 2}"#
        let data = try #require(legacy.data(using: .utf8))

        let state = try JSONDecoder().decode(QueryActivityAttributes.ContentState.self, from: data)

        #expect(state.lastUpdatedAt == state.startedAt)
        #expect(state.elapsedWhenLastAlive == 0)
    }

    @Test
    func anOutcomeSurvivesARoundTrip() throws {
        let original = QueryActivityAttributes.ContentState(
            startedAt: referenceNow,
            endedAt: referenceNow.addingTimeInterval(3),
            rowsStreamed: 9,
            outcome: .stopped
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueryActivityAttributes.ContentState.self, from: data)

        #expect(decoded == original)
    }
}
