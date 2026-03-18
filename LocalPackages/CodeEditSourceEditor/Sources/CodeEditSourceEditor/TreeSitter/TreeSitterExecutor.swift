//
//  TreeSitterExecutor.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 9/2/24.
//

import Foundation

/// This class provides a thread-safe API for executing `tree-sitter` operations synchronously or asynchronously.
///
/// `tree-sitter` can take a potentially long time to parse a document. Long enough that we may decide to free up the
/// main thread and do syntax highlighting when the parse is complete. To accomplish this, the ``TreeSitterClient``
/// uses a ``TreeSitterExecutor`` to perform both sync and async operations.
///
/// Sync operations occur when the ``TreeSitterClient`` _both_ a) estimates that a query or parse will not take too
/// long on the main thread to gum up interactions, and b) there are no async operations already in progress. If either
/// condition is false, the operation must be performed asynchronously or is cancelled. Finally, async operations may
/// need to be cancelled, and should cancel quickly based on the level of access required for the operation
/// (see ``TreeSitterExecutor/Priority``).
///
/// The ``TreeSitterExecutor`` facilitates this requirement by providing a simple API that ``TreeSitterClient`` can use
/// to attempt sync operations, queue async operations, and cancel async operations. It does this by managing a queue
/// of tasks to execute in order. Each task is given a priority when queued and all queue operations are made thread
/// safe using a lock.
///
/// To check if a sync operation can occur, the queue is checked. If empty or the lock could not be acquired, the sync
/// operation is queued without a swift `Task` and executed. This forces parallel sync attempts to be made async and
/// will run after the original sync operation is finished.
///
/// Async operations are added to the queue in a detached `Task`. Before they execute their operation callback, they
/// first ensure they are next in the queue. This is done by acquiring the queue lock and checking the queue contents.
/// To avoid lock contention (and essentially implementing a spinlock), the task sleeps for a few milliseconds
/// (defined by ``TreeSitterClient/Constants/taskSleepDuration``) after failing to be next in the queue. Once up for
/// running, the operation is executed. Finally, the lock is acquired again and the task is removed from the queue.
///
final package class TreeSitterExecutor {
    /// The priority of an operation. These are used to conditionally cancel operations.
    /// See ``TreeSitterExecutor/cancelAll(below:)``
    enum Priority: Comparable {
        case access
        case edit
        case reset
        case all
    }

    private struct QueueItem {
        let task: (Task<Void, Never>)?
        let id: UUID
        let priority: Priority
    }

    private let lock = NSLock()
    private var queuedTasks: [QueueItem] = []

    enum Error: Swift.Error {
        case syncUnavailable
    }

    /// Attempt to execute a synchronous operation. Thread safe.
    /// - Parameter operation: The callback to execute.
    /// - Returns: Returns a `.failure` with a ``TreeSitterExecutor/Error/syncUnavailable`` error if the operation
    ///            cannot be safely performed synchronously.
    @discardableResult
    func execSync<T>(_ operation: () -> T) -> Result<T, Error> {
        guard let queueItemID = addSyncTask() else {
            return .failure(Error.syncUnavailable)
        }
        let returnVal = operation() // Execute outside critical area.
        // Critical section, modifying the queue.
        lock.withLock {
            queuedTasks.removeAll(where: { $0.id == queueItemID })
        }
        return .success(returnVal)
    }

    private func addSyncTask() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard queuedTasks.isEmpty else {
            return nil
        }
        let id = UUID()
        queuedTasks.append(QueueItem(task: nil, id: id, priority: .all))
        return id
    }

    /// Execute an operation asynchronously. Thread safe.
    /// - Parameters:
    ///   - priority: The priority given to the operation. Defaults to ``TreeSitterExecutor/Priority/access``.
    ///   - operation: The operation to execute. It is up to the caller to exit _ASAP_ if the task is cancelled.
    ///   - onCancel: A callback called if the operation was cancelled.
    func execAsync(priority: Priority = .access, operation: @escaping () -> Void, onCancel: @escaping () -> Void) {
        // Critical section, modifying the queue
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        let task = Task(priority: .userInitiated) { // __This executes outside the outer lock's control__
            while self.lock.withLock({ !canTaskExec(id: id, priority: priority) }) {
                // Instead of yielding, sleeping frees up the CPU due to time off the CPU and less lock contention
                try? await Task.sleep(for: TreeSitterClient.Constants.taskSleepDuration)
                guard !Task.isCancelled else {
                    removeTask(id)
                    onCancel()
                    return
                }
            }

            guard !Task.isCancelled else {
                removeTask(id)
                onCancel()
                return
            }

            operation()

            if Task.isCancelled {
                onCancel()
            }

            removeTask(id)
            // __Back to outer lock control__
        }
        queuedTasks.append(QueueItem(task: task, id: id, priority: priority))
    }

    func exec<T>(_ priority: Priority = .access, operation: @escaping () -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            execAsync(priority: priority) {
                continuation.resume(returning: operation())
            } onCancel: {
                continuation.resume(throwing: CancellationError())
            }

        }
    }

    private func removeTask(_ id: UUID) {
        self.lock.withLock {
            self.queuedTasks.removeAll(where: { $0.id == id })
        }
    }

    /// Allow concurrent ``TreeSitterExecutor/Priority/access`` operations to run. Thread safe.
    private func canTaskExec(id: UUID, priority: Priority) -> Bool {
        if priority != .access {
            return queuedTasks.first?.id == id
        }

        for task in queuedTasks {
            if task.priority != .access {
                return false
            } else {
                return task.id == id
            }
        }
        assertionFailure("Task asking if it can exec but it's not in the queue.")
        return false
    }

    /// Cancels all queued or running tasks below the given priority. Thread safe.
    /// - Note: Does not guarantee work stops immediately. It is up to the caller to provide callbacks that exit
    ///         ASAP when a task is cancelled.
    /// - Parameter priority: The priority to cancel below. Eg: if given `reset`, will cancel all `edit` and `access`
    ///                       operations.
    func cancelAll(below priority: Priority) {
        lock.withLock {
            queuedTasks.forEach { item in
                if item.priority < priority && !(item.task?.isCancelled ?? true) {
                    item.task?.cancel()
                }
            }
        }
    }

    deinit {
        lock.withLock {
            queuedTasks.forEach { item in
                item.task?.cancel()
            }
        }
    }
}
