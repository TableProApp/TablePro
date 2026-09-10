import Foundation

/// The signal a row stream's producer polls to learn that its consumer stopped.
///
/// Terminating an `AsyncThrowingStream` runs its `onTermination` handler and nothing else, so a
/// producer that does not poll runs to completion no matter what the consumer did. Measured on a
/// producer occupying a serial queue with 40 batches of work: polling this flag stopped it after
/// one batch, while hopping the drain onto the producer's own queue stopped nothing and ran the
/// drain only after the whole read had finished.
public final class PluginStreamAbort: @unchecked Sendable {
    private let lock = NSLock()
    private var _isAborted = false
    private var actions: [@Sendable () -> Void] = []

    public init() {}

    public var isAborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isAborted
    }

    /// Registers work to run when the consumer stops, for a producer that also needs an active
    /// signal such as cancelling its own task. Registering here rather than assigning
    /// `continuation.onTermination` is what keeps both from clobbering each other; the stream's
    /// handler belongs to `PluginRowStream.make`. Runs immediately if the abort already fired.
    public func onAbort(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if _isAborted {
            lock.unlock()
            action()
            return
        }
        actions.append(action)
        lock.unlock()
    }

    public func abort() {
        lock.lock()
        let alreadyAborted = _isAborted
        _isAborted = true
        let pending = actions
        actions.removeAll()
        lock.unlock()
        guard !alreadyAborted else { return }
        for action in pending { action() }
    }
}

public enum PluginRowStream {
    /// Builds a row stream whose abort signal is already wired to its termination.
    ///
    /// The handler is installed before `build` runs and sets the flag synchronously on whichever
    /// thread terminated the stream, so a producer that has not started yet still sees it and can
    /// decline to send the query at all. A producer that hops the signal onto its own serial queue
    /// instead sees it only after it has finished, which is the defect this exists to make
    /// unrepeatable.
    ///
    /// Termination follows the lifetime of the stream, not the consumer's `break`: a consumer that
    /// stops reading but holds the stream in scope has not terminated it.
    public static func make(
        bufferingPolicy: AsyncThrowingStream<PluginStreamElement, Error>.Continuation.BufferingPolicy = .unbounded,
        _ build: @escaping @Sendable (
            AsyncThrowingStream<PluginStreamElement, Error>.Continuation,
            PluginStreamAbort
        ) -> Void
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let abort = PluginStreamAbort()
        return AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            continuation.onTermination = { @Sendable _ in abort.abort() }
            build(continuation, abort)
        }
    }
}
