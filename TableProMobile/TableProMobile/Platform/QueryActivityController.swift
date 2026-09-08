import ActivityKit
import Foundation
import os
import UIKit

@MainActor
protocol LiveActivityHandle {
    var id: String { get }
    var state: QueryActivityAttributes.ContentState { get }
    func update(state: QueryActivityAttributes.ContentState, staleDate: Date?) async
    func end(state: QueryActivityAttributes.ContentState) async
}

@MainActor
protocol LiveActivityStore {
    var areActivitiesEnabled: Bool { get }
    var liveActivities: [any LiveActivityHandle] { get }
    func request(
        attributes: QueryActivityAttributes,
        state: QueryActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> any LiveActivityHandle
}

struct QueryExecutionToken: Hashable, Sendable {
    fileprivate let id: UUID

    fileprivate init() {
        id = UUID()
    }
}

@MainActor
final class QueryActivityController {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryActivity")
    private static let taskName = "End query Live Activity"
    private static let heartbeatInterval = QueryActivityStaleWindow.seconds / 2

    private struct Execution {
        let connectionId: UUID
        let handle: any LiveActivityHandle
        var lastUpdatedAt: Date
        var isEnding = false
    }

    private let store: any LiveActivityStore
    private let asserter: any BackgroundTaskAsserting
    private let now: () -> Date

    private var executions: [QueryExecutionToken: Execution] = [:]
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var assertionHolders = 0
    private var reapTask: Task<Void, Never>?

    init(
        store: any LiveActivityStore = ActivityKitLiveActivityStore(),
        asserter: any BackgroundTaskAsserting = UIApplication.shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.asserter = asserter
        self.now = now
    }

    var ownedActivityIds: Set<String> {
        Set(executions.values.map(\.handle.id))
    }

    func reapOrphans() async {
        if let inFlight = reapTask {
            return await inFlight.value
        }
        let task = Task { await self.endOrphans() }
        reapTask = task
        await task.value
        reapTask = nil
    }

    func start(
        connectionId: UUID,
        connectionName: String,
        query: String,
        startedAt: Date
    ) async -> QueryExecutionToken? {
        await reapOrphans()
        guard store.areActivitiesEnabled else { return nil }

        let attributes = QueryActivityAttributes(
            connectionId: connectionId,
            connectionName: connectionName,
            queryPreview: preview(for: query)
        )
        let state = QueryActivityAttributes.ContentState(startedAt: startedAt, lastUpdatedAt: startedAt)
        do {
            let handle = try store.request(
                attributes: attributes,
                state: state,
                staleDate: startedAt.addingTimeInterval(QueryActivityStaleWindow.seconds)
            )
            let token = QueryExecutionToken()
            executions[token] = Execution(connectionId: connectionId, handle: handle, lastUpdatedAt: startedAt)
            return token
        } catch {
            Self.logger.warning("Could not start the query Live Activity: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func update(token: QueryExecutionToken?, rowsStreamed: Int) async {
        guard let token, let execution = executions[token], !execution.isEnding else { return }
        let instant = now()
        let rowsChanged = execution.handle.state.rowsStreamed != rowsStreamed
        let heartbeatDue = instant.timeIntervalSince(execution.lastUpdatedAt) >= Self.heartbeatInterval
        guard rowsChanged || heartbeatDue else { return }

        var state = execution.handle.state
        state.rowsStreamed = rowsStreamed
        state.lastUpdatedAt = instant
        executions[token]?.lastUpdatedAt = instant
        await execution.handle.update(
            state: state,
            staleDate: instant.addingTimeInterval(QueryActivityStaleWindow.seconds)
        )
    }

    func end(token: QueryExecutionToken?, outcome: QueryActivityAttributes.Outcome) async {
        guard let token, let execution = executions[token], !execution.isEnding else { return }
        executions[token]?.isEnding = true
        await end(execution: execution, outcome: outcome)
        executions.removeValue(forKey: token)
    }

    func endEverything(forConnection connectionId: UUID, outcome: QueryActivityAttributes.Outcome) async {
        let matching = executions.filter { $0.value.connectionId == connectionId && !$0.value.isEnding }
        guard !matching.isEmpty else { return }
        for token in matching.keys {
            executions[token]?.isEnding = true
        }
        for (token, execution) in matching {
            await end(execution: execution, outcome: outcome)
            executions.removeValue(forKey: token)
        }
    }

    private func end(execution: Execution, outcome: QueryActivityAttributes.Outcome) async {
        beginAssertion()
        defer { endAssertion() }
        await execution.handle.end(state: execution.handle.state.ended(as: outcome, at: now()))
    }

    // MARK: - Orphans

    private func endOrphans() async {
        let owned = ownedActivityIds
        let orphans = store.liveActivities.filter { !owned.contains($0.id) }
        guard !orphans.isEmpty else { return }
        Self.logger.info("Ending \(orphans.count, privacy: .public) orphaned query Live Activities")
        beginAssertion()
        defer { endAssertion() }
        for orphan in orphans {
            await orphan.end(state: orphan.state.ended(as: .interrupted, at: now()))
        }
    }

    // MARK: - Privacy

    private func preview(for query: String) -> String {
        guard !AppPreferences.hidesQueryPreviewInActivity else {
            return String(localized: "Running query")
        }
        return String(query.prefix(60))
    }

    // MARK: - Background assertion

    private func beginAssertion() {
        assertionHolders += 1
        guard taskIdentifier == .invalid else { return }
        taskIdentifier = asserter.beginBackgroundTask(name: Self.taskName) { [weak self] in
            self?.expireAssertion()
        }
    }

    private func endAssertion() {
        assertionHolders = max(0, assertionHolders - 1)
        guard assertionHolders == 0 else { return }
        releaseAssertion()
    }

    private func expireAssertion() {
        Self.logger.warning("Background time expired before the query Live Activity was ended")
        assertionHolders = 0
        releaseAssertion()
    }

    private func releaseAssertion() {
        guard taskIdentifier != .invalid else { return }
        asserter.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
    }
}

// MARK: - ActivityKit

@MainActor
struct ActivityKitLiveActivityStore: LiveActivityStore {
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var liveActivities: [any LiveActivityHandle] {
        Activity<QueryActivityAttributes>.activities.map(ActivityKitHandle.init)
    }

    func request(
        attributes: QueryActivityAttributes,
        state: QueryActivityAttributes.ContentState,
        staleDate: Date?
    ) throws -> any LiveActivityHandle {
        let activity = try Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: staleDate)
        )
        return ActivityKitHandle(activity: activity)
    }
}

@MainActor
private struct ActivityKitHandle: LiveActivityHandle {
    let activity: Activity<QueryActivityAttributes>

    var id: String { activity.id }
    var state: QueryActivityAttributes.ContentState { activity.content.state }

    func update(state: QueryActivityAttributes.ContentState, staleDate: Date?) async {
        nonisolated(unsafe) let target = activity
        await target.update(.init(state: state, staleDate: staleDate))
    }

    func end(state: QueryActivityAttributes.ContentState) async {
        nonisolated(unsafe) let target = activity
        await target.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
    }
}
