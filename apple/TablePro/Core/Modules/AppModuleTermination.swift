import Foundation
import os

@MainActor
enum AppModuleTermination {
    static let stopLimit: Duration = .seconds(5)

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppModules")

    // A stop waiting on a server that no longer answers must not hold the quit, so it gets a limit.
    static func stopModuleWork() async {
        guard RoutineDebugSessions.shared.hasActiveSessions else { return }
        let finished = await runCapped(at: stopLimit) {
            await RoutineDebugSessions.shared.stopAll()
        }
        if !finished {
            logger.warning("Routine debug sessions were still stopping when the quit limit passed")
        }
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
