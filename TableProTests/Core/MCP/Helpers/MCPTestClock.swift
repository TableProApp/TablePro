import Foundation
import TableProPluginKit
@testable import TablePro

public actor MCPTestClock: MCPClock {
    private var currentDate: Date
    private var pendingSleeps: [PendingSleep] = []

    private struct PendingSleep {
        let dueAt: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.currentDate = start
    }

    public func now() -> Date {
        currentDate
    }

    public func sleep(for duration: Duration) async throws {
        let dueAt = currentDate.addingTimeInterval(Self.seconds(of: duration))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingSleeps.append(PendingSleep(dueAt: dueAt, continuation: continuation))
        }
    }

    public func advance(by duration: Duration) async {
        let target = currentDate.addingTimeInterval(Self.seconds(of: duration))
        currentDate = target

        let due = pendingSleeps.filter { $0.dueAt <= target }
        pendingSleeps.removeAll { $0.dueAt <= target }
        for sleep in due {
            sleep.continuation.resume()
        }

        await Task.yield()
    }

    public func setNow(_ date: Date) async {
        currentDate = date
        let due = pendingSleeps.filter { $0.dueAt <= date }
        pendingSleeps.removeAll { $0.dueAt <= date }
        for sleep in due {
            sleep.continuation.resume()
        }
    }

    public func cancelAllSleeps() {
        let cancelled = pendingSleeps
        pendingSleeps.removeAll()
        for sleep in cancelled {
            sleep.continuation.resume(throwing: CancellationError())
        }
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}
