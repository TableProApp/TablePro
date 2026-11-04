import Foundation
import os

public enum ProgressReportingDownload {
    // Ends with 1 on success. Reports nothing before that when the server sends no Content-Length.
    public static func download(
        _ url: URL,
        with session: URLSession,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> (URL, URLResponse) {
        let observer = DownloadProgressObserver()
        let forwarding = Task {
            for await fraction in observer.fractions {
                await progress(fraction)
            }
        }
        do {
            let result = try await session.download(from: url, delegate: observer)
            observer.finish(isComplete: true)
            await forwarding.value
            return result
        } catch {
            observer.finish(isComplete: false)
            forwarding.cancel()
            throw error
        }
    }
}

// The async download sends a task delegate no byte callbacks, but the task's own progress moves.
private final class DownloadProgressObserver: NSObject, URLSessionTaskDelegate, Sendable {
    let fractions: AsyncStream<Double>
    private let continuation: AsyncStream<Double>.Continuation
    private let observation = OSAllocatedUnfairLock<NSKeyValueObservation?>(uncheckedState: nil)

    override init() {
        (fractions, continuation) = AsyncStream.makeStream(of: Double.self)
        super.init()
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let continuation = continuation
        let observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            // Without a Content-Length the fraction creeps on a guess; the UI stays indeterminate.
            guard task.countOfBytesExpectedToReceive > 0 else { return }
            continuation.yield(progress.fractionCompleted)
        }
        self.observation.withLockUnchecked { $0 = observation }
    }

    func finish(isComplete: Bool) {
        observation.withLockUnchecked { observation in
            observation?.invalidate()
            observation = nil
        }
        if isComplete {
            continuation.yield(1)
        }
        continuation.finish()
    }
}
