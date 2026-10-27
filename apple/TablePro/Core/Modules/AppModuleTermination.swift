import Foundation

@MainActor
enum AppModuleTermination {
    static let stopLimit: Duration = .seconds(5)

    // A stop waiting on a server that no longer answers must not hold the quit: `stopAll` returns by its deadline,
    // the same one the runs close their connections at.
    static func stopModuleWork() async {
        guard RoutineDebugSessions.shared.hasActiveSessions else { return }
        await RoutineDebugSessions.shared.stopAll(timeout: stopLimit)
    }

    // True when `work` returned before the limit. Work still running at the limit is left to the process exit.
    static func runCapped(
        at limit: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        _ work: @escaping @MainActor @Sendable () async -> Void
    ) async -> Bool {
        var deadline: Task<Void, Never>?
        let outcomes = AsyncStream<Bool> { continuation in
            Task { @MainActor in
                await work()
                continuation.yield(true)
                continuation.finish()
            }
            deadline = Task {
                try? await clock.sleep(for: limit)
                continuation.yield(false)
                continuation.finish()
            }
        }
        var finished = false
        for await outcome in outcomes {
            finished = outcome
            break
        }
        deadline?.cancel()
        return finished
    }
}
