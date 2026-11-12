import Foundation

// Terminating an AsyncThrowingStream only runs its onTermination handler, so a producer learns that its consumer
// stopped by polling `isAborted`, and learns that its consumer fell behind by sending through `send(_:to:)`.
public final class PluginStreamAbort: @unchecked Sendable {
    public typealias Continuation = AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    public typealias ExportContinuation = AsyncThrowingStream<PluginExportStreamElement, Error>.Continuation

    private let condition = NSCondition()
    private var _isAborted = false
    private var actions: [@Sendable () -> Void] = []
    private let readAhead: Int?
    private var sentBatches = 0
    private var takenBatches = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID = 0

    public init() {
        readAhead = nil
    }

    init(readAhead: Int) {
        self.readAhead = max(readAhead, 1)
    }

    public var isAborted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return _isAborted
    }

    // For a producer that also needs an active signal, such as cancelling its own task. The stream's onTermination
    // belongs to `PluginRowStream.make`, so registering here keeps the two from clobbering each other.
    public func onAbort(_ action: @escaping @Sendable () -> Void) {
        condition.lock()
        if _isAborted {
            condition.unlock()
            action()
            return
        }
        actions.append(action)
        condition.unlock()
    }

    // The actions run before a waiting producer wakes, so it sees what they did, such as its cancelled task.
    public func abort() {
        condition.lock()
        let alreadyAborted = _isAborted
        _isAborted = true
        let pending = actions
        actions.removeAll()
        condition.unlock()
        if !alreadyAborted {
            for action in pending { action() }
        }
        condition.lock()
        let parked = Array(waiters.values)
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for waiter in parked { waiter.resume() }
    }

    // Blocks the calling thread, so it is for a producer looping on a queue or thread of its own. Returns once the
    // consumer is fewer than the stream's read-ahead batches behind, once it stops, or after `maximumPause` seconds,
    // for a server that drops a connection left unread that long; past that the producer reads on as before. A batch
    // a bounded buffer dropped is not counted, since the consumer never takes it.
    public func send(_ rows: [PluginRow], to continuation: Continuation, maximumPause: TimeInterval? = nil) {
        guard case .enqueued = continuation.yield(.rows(rows)) else { return }
        waitForConsumer(maximumPause: maximumPause)
    }

    // The same for a producer running in a task: it suspends instead of blocking, and a cancelled task returns.
    public func send(_ rows: [PluginRow], to continuation: Continuation, maximumPause: TimeInterval? = nil) async {
        guard case .enqueued = continuation.yield(.rows(rows)) else { return }
        await waitForConsumer(maximumPause: maximumPause)
    }

    public func send(
        _ rows: [PluginRow],
        documents: [PluginExportDocument]?,
        to continuation: ExportContinuation,
        maximumPause: TimeInterval? = nil
    ) {
        guard case .enqueued = continuation.yield(.rows(rows, documents: documents)) else { return }
        waitForConsumer(maximumPause: maximumPause)
    }

    public func send(
        _ rows: [PluginRow],
        documents: [PluginExportDocument]?,
        to continuation: ExportContinuation,
        maximumPause: TimeInterval? = nil
    ) async {
        guard case .enqueued = continuation.yield(.rows(rows, documents: documents)) else { return }
        await waitForConsumer(maximumPause: maximumPause)
    }

    private func waitForConsumer(maximumPause: TimeInterval?) {
        let deadline = maximumPause.map { Date(timeIntervalSinceNow: $0) }
        condition.lock()
        defer { condition.unlock() }
        sentBatches += 1
        while isBehind {
            if let deadline {
                guard condition.wait(until: deadline) else { return }
            } else {
                condition.wait()
            }
        }
    }

    private func waitForConsumer(maximumPause: TimeInterval?) async {
        let id: Int? = {
            condition.lock()
            defer { condition.unlock() }
            sentBatches += 1
            guard isBehind else { return nil }
            nextWaiterID += 1
            return nextWaiterID
        }()
        guard let id else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                condition.lock()
                guard isBehind, !Task.isCancelled else {
                    condition.unlock()
                    waiter.resume()
                    return
                }
                waiters[id] = waiter
                condition.unlock()
                if let maximumPause {
                    DispatchQueue.global().asyncAfter(deadline: .now() + maximumPause) { [weak self] in
                        self?.release(id)
                    }
                }
            }
        } onCancel: {
            release(id)
        }
    }

    func consumerTookBatch() {
        condition.lock()
        takenBatches += 1
        guard !isBehind else {
            condition.unlock()
            return
        }
        let parked = Array(waiters.values)
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        for waiter in parked { waiter.resume() }
    }

    // Read under the lock.
    private var isBehind: Bool {
        guard let readAhead, !_isAborted else { return false }
        return sentBatches - takenBatches >= readAhead
    }

    private func release(_ id: Int) {
        condition.lock()
        let waiter = waiters.removeValue(forKey: id)
        condition.unlock()
        waiter?.resume()
    }
}

public enum PluginRowStream {
    // Batches a producer that sends through `PluginStreamAbort.send` may have unread before it waits.
    static let readAhead = 2

    // The abort handler is installed before `build` runs and sets the flag on whichever thread terminated the stream,
    // so a producer that has not started yet still sees it and can decline to send the query. Termination follows the
    // stream's lifetime, not the consumer's `break`: a consumer that stops reading but holds the stream has not ended it.
    // The stream handed back is pulled from the producer's, so each batch the consumer takes is counted for `send`.
    public static func make(
        bufferingPolicy: AsyncThrowingStream<PluginStreamElement, Error>.Continuation.BufferingPolicy = .unbounded,
        _ build: @escaping @Sendable (
            AsyncThrowingStream<PluginStreamElement, Error>.Continuation,
            PluginStreamAbort
        ) -> Void
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        paced(bufferingPolicy: bufferingPolicy, build) { element in
            if case .rows = element { return true }
            return false
        }
    }

    // The same for a producer that hands documents along with its rows.
    public static func makeExport(
        _ build: @escaping @Sendable (
            AsyncThrowingStream<PluginExportStreamElement, Error>.Continuation,
            PluginStreamAbort
        ) -> Void
    ) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        paced(bufferingPolicy: .unbounded, build) { element in
            if case .rows = element { return true }
            return false
        }
    }

    private static func paced<Element: Sendable>(
        bufferingPolicy: AsyncThrowingStream<Element, Error>.Continuation.BufferingPolicy,
        _ build: @escaping @Sendable (AsyncThrowingStream<Element, Error>.Continuation, PluginStreamAbort) -> Void,
        isBatch: @escaping @Sendable (Element) -> Bool
    ) -> AsyncThrowingStream<Element, Error> {
        let abort = PluginStreamAbort(readAhead: readAhead)
        let produced = AsyncThrowingStream<Element, Error>(bufferingPolicy: bufferingPolicy) { continuation in
            continuation.onTermination = { @Sendable _ in abort.abort() }
            build(continuation, abort)
        }
        let source = PacedSource(produced, abort: abort, isBatch: isBatch)
        return AsyncThrowingStream(unfolding: { try await source.next() })
    }
}

// One consumer reads the stream, so one call at a time reaches the iterator.
private final class PacedSource<Element: Sendable>: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Element, Error>.AsyncIterator
    private let abort: PluginStreamAbort
    private let isBatch: @Sendable (Element) -> Bool

    init(_ stream: AsyncThrowingStream<Element, Error>, abort: PluginStreamAbort, isBatch: @escaping @Sendable (Element) -> Bool) {
        iterator = stream.makeAsyncIterator()
        self.abort = abort
        self.isBatch = isBatch
    }

    func next() async throws -> Element? {
        let element = try await iterator.next()
        if let element, isBatch(element) { abort.consumerTookBatch() }
        return element
    }
}
