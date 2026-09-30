import Foundation

protocol PluginURLSessionCancellable: AnyObject {
    func cancel()
}

extension URLSessionTask: PluginURLSessionCancellable {}

final class PluginURLSessionTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: (any PluginURLSessionCancellable)?
    private var isCancelled = false

    func set(_ task: any PluginURLSessionCancellable) {
        let shouldCancel = lock.withLock {
            guard !isCancelled else { return true }
            self.task = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func finish() {
        lock.withLock { task = nil }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            let task = task
            self.task = nil
            return task
        }
        task?.cancel()
    }
}
