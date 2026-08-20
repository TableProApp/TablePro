import Foundation

public final class SingleResumeGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    private var settled = false

    public init() {}

    public func install(_ continuation: CheckedContinuation<Value, Error>, alreadyCancelled: Bool) {
        lock.lock()
        if alreadyCancelled, !settled {
            settled = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    public func win(_ value: Value) -> Bool {
        settle(.success(value))
    }

    public func fail(_ error: Error) {
        _ = settle(.failure(error))
    }

    @discardableResult
    private func settle(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        if settled {
            lock.unlock()
            return false
        }
        settled = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            outcome = result
            lock.unlock()
        }
        return true
    }
}

public func runCancellableBlocking<T: Sendable>(
    on queue: DispatchQueue,
    deadline: DispatchTimeInterval? = nil,
    deadlineQueue: DispatchQueue = .global(qos: .userInitiated),
    timeoutError: @escaping @Sendable () -> Error = { CancellationError() },
    work: @escaping @Sendable () throws -> T,
    discardLateResult: @escaping @Sendable (T) -> Void = { _ in }
) async throws -> T {
    let gate = SingleResumeGate<T>()
    if let deadline {
        deadlineQueue.asyncAfter(deadline: .now() + deadline) {
            gate.fail(timeoutError())
        }
    }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            gate.install(continuation, alreadyCancelled: Task.isCancelled)
            queue.async {
                do {
                    let value = try work()
                    if !gate.win(value) {
                        discardLateResult(value)
                    }
                } catch {
                    gate.fail(error)
                }
            }
        }
    } onCancel: {
        gate.fail(CancellationError())
    }
}
