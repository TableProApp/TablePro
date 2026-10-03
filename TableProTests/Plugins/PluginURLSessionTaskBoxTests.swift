import Foundation
import Testing

private final class RecordingURLSessionTask: PluginURLSessionCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func cancel() {
        lock.withLock { cancellations += 1 }
    }
}

struct PluginURLSessionTaskBoxTests {
    @Test("Cancellation delivered before task registration cancels the late task")
    func cancellationBeforeRegistration() {
        let box = PluginURLSessionTaskBox()
        let task = RecordingURLSessionTask()

        box.cancel()
        box.set(task)

        #expect(task.cancellationCount == 1)
    }

    @Test("Cancellation delivered after task registration cancels the current task")
    func cancellationAfterRegistration() {
        let box = PluginURLSessionTaskBox()
        let task = RecordingURLSessionTask()
        box.set(task)

        box.cancel()
        box.cancel()

        #expect(task.cancellationCount == 1)
    }

    @Test("Cancellation delivered after completion cannot touch the completed task")
    func cancellationAfterCompletion() {
        let box = PluginURLSessionTaskBox()
        let task = RecordingURLSessionTask()
        box.set(task)
        box.finish()

        box.cancel()

        #expect(task.cancellationCount == 0)
    }
}
