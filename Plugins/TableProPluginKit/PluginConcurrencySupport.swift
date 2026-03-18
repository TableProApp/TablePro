import Foundation

public func pluginDispatchAsync<T: Sendable>(
    on queue: DispatchQueue,
    execute work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        queue.async {
            do {
                let result = try work()
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public func pluginDispatchAsync(
    on queue: DispatchQueue,
    execute work: @escaping @Sendable () throws -> Void
) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        queue.async {
            do {
                try work()
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public func pluginDispatchAsyncCancellable<T: Sendable>(
    on queue: DispatchQueue,
    cancellationCheck: (@Sendable () -> Bool)? = nil,
    execute work: @escaping @Sendable () throws -> T
) async throws -> T {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let check = cancellationCheck, check() {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    } onCancel: {}
}
