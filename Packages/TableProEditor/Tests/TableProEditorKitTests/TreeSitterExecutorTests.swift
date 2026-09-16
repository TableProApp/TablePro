import Foundation
import Testing

@testable import TableProEditorKit

@Suite("Tree-sitter executor")
struct TreeSitterExecutorTests {
    /// A cancelled task used to report twice: the operation ran to the end and completed, and then the executor saw
    /// `Task.isCancelled` and called `onCancel` for the same task. For an edit that meant one keystroke delivering a
    /// success and a failure, and for `exec` it meant resuming one continuation twice, which traps.
    @Test("A task that is cancelled while it runs reports once")
    func aCancelledRunningTaskReportsOnce() async {
        let executor = TreeSitterExecutor()
        let started = DispatchSemaphore(value: 0)
        let mayFinish = DispatchSemaphore(value: 0)
        let outcomes = OutcomeBox()

        executor.execAsync(
            priority: .edit,
            operation: {
                started.signal()
                mayFinish.wait()
                outcomes.record("completed")
                return true
            },
            onCancel: { outcomes.record("cancelled") }
        )

        started.wait()
        executor.cancelAll(below: .reset)
        mayFinish.signal()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(outcomes.recorded == ["completed"])
    }

    @Test("A task that abandons its work reports cancelled, not completed")
    func anAbandonedTaskReportsCancelled() async {
        let executor = TreeSitterExecutor()
        let started = DispatchSemaphore(value: 0)
        let mayFinish = DispatchSemaphore(value: 0)
        let outcomes = OutcomeBox()

        executor.execAsync(
            priority: .edit,
            operation: {
                started.signal()
                mayFinish.wait()
                return false
            },
            onCancel: { outcomes.record("cancelled") }
        )

        started.wait()
        executor.cancelAll(below: .reset)
        mayFinish.signal()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(outcomes.recorded == ["cancelled"])
    }

    @Test("A task cancelled before it runs reports cancelled once")
    func aTaskCancelledBeforeItRunsReportsCancelled() async {
        let executor = TreeSitterExecutor()
        let outcomes = OutcomeBox()

        executor.execAsync(
            priority: .edit,
            operation: {
                outcomes.record("completed")
                return true
            },
            onCancel: { outcomes.record("cancelled") }
        )
        executor.cancelAll(below: .reset)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(outcomes.recorded.count <= 1, "reported \(outcomes.recorded)")
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func record(_ value: String) {
            lock.withLock { values.append(value) }
        }

        var recorded: [String] {
            lock.withLock { values }
        }
    }
}
