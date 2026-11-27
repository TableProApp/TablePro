import Dispatch

// Runs an actor that owns a SQLite handle on a serial queue of its own instead of Swift's cooperative pool. A step
// blocks its thread for the whole statement, a wait on a locked database included, and the pool has about one thread
// per core, so a few long statements there would stall every other task in the process. A queue's thread may block.
// The actor's guarantees stay: one job at a time, and a statement that never awaits runs start to end on that queue.
public final class SQLiteConnectionExecutor: SerialExecutor {
    private let queue: DispatchQueue

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    // `enqueue(_: UnownedJob)`, not the `ExecutorJob` form: that one needs macOS 14 and iOS 17.
    public func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async {
            job.runSynchronously(on: executor)
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
