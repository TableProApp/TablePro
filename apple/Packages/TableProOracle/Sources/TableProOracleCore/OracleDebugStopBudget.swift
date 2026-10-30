import Foundation

// `stop()` returns within 3 seconds: the host closes the session's transport 5 seconds after asking, and over a tunnel
// nothing reaches the server after that.
public enum OracleDebugStopBudget {
    public static let total: Duration = .seconds(3)
    // Kept back from the total for the rollback and detach that follow the target's end.
    public static let cleanup: Duration = .milliseconds(500)

    public enum KillOutcome: Sendable, Equatable {
        // ORA-00031 "session marked for kill": the server ends the session at its next check (measured within a second).
        case marked
        // ORA-01031 without ALTER SYSTEM, or no SERIAL# to name the session.
        case refused
    }

    // A DBMS_DEBUG target running between breakpoints reads nothing the supervisor sends, so the kill goes first, with
    // no grace period; what is left of the budget waits for the end, which a refused kill leaves to the routine itself.
    static func endRunningTarget<C: Clock>(
        isolation: isolated (any Actor)? = #isolation,
        clock: C,
        budget: Duration = total - cleanup,
        kill: () async -> KillOutcome,
        waitForEnd: (Duration) async -> Bool
    ) async -> Bool where C.Duration == Duration {
        let deadline = clock.now.advanced(by: budget)
        _ = await kill()
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { return false }
        return await waitForEnd(remaining)
    }

    static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
