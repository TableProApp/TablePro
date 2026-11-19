import Foundation

struct BigQueryStopLifecycle: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case notStarted
        case cancelledBeforeStart
        case running(bodySent: Bool)
        case stopped(callerReleased: Bool)
        case answered
        case failed
        case answeredAfterStop
        case failedAfterStop
    }

    enum Event: Equatable, Sendable, CaseIterable {
        case start
        case attemptStarted
        case bodySent
        case stop
        case answer
        case failure
        case graceElapsed
        case limitElapsed
    }

    enum CallerOutcome: Equatable, Sendable {
        case answer
        case error
        case cancelled
    }

    enum Effect: Equatable, Sendable {
        case launchRequest
        case releaseCaller(CallerOutcome)
        case armTimer
        case cancelTimer
        case cancelRequest
        case handOverAnswer
    }

    private(set) var stage: Stage

    init(stage: Stage = .notStarted) {
        self.stage = stage
    }

    var isStopped: Bool {
        switch stage {
        case .notStarted, .running, .answered, .failed:
            false
        case .cancelledBeforeStart, .stopped, .answeredAfterStop, .failedAfterStop:
            true
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch stage {
        case .notStarted:
            switch event {
            case .start:
                stage = .running(bodySent: false)
                return [.launchRequest]
            case .stop:
                stage = .cancelledBeforeStart
                return []
            case .attemptStarted, .bodySent, .answer, .failure, .graceElapsed, .limitElapsed:
                return []
            }
        case .cancelledBeforeStart:
            switch event {
            case .start:
                return [.releaseCaller(.cancelled)]
            case .attemptStarted, .bodySent, .stop, .answer, .failure, .graceElapsed, .limitElapsed:
                return []
            }
        case .running(let bodySent):
            switch event {
            case .attemptStarted:
                stage = .running(bodySent: false)
                return []
            case .bodySent:
                stage = .running(bodySent: true)
                return []
            case .answer:
                stage = .answered
                return [.releaseCaller(.answer)]
            case .failure:
                stage = .failed
                return [.releaseCaller(.error)]
            case .stop:
                // Until its body has left, the server cannot run the statement, so Stop ends the request as main did.
                stage = .stopped(callerReleased: false)
                return bodySent ? [.armTimer] : [.armTimer, .cancelRequest]
            case .start, .graceElapsed, .limitElapsed:
                return []
            }
        case .stopped(let callerReleased):
            let release: [Effect] = callerReleased ? [] : [.releaseCaller(.cancelled)]
            switch event {
            case .answer:
                stage = .answeredAfterStop
                return release + [.cancelTimer, .handOverAnswer]
            case .failure:
                stage = .failedAfterStop
                return release + [.cancelTimer]
            case .graceElapsed:
                stage = .stopped(callerReleased: true)
                return release
            case .limitElapsed:
                stage = .stopped(callerReleased: true)
                return release + [.cancelRequest]
            case .start, .attemptStarted, .bodySent, .stop:
                return []
            }
        case .answered, .failed, .answeredAfterStop, .failedAfterStop:
            return []
        }
    }
}

public struct BigQueryRequestSignals: Sendable {
    public let isStopped: @Sendable () -> Bool
    // False once Stop has come; otherwise a new attempt starts with its body not yet sent.
    public let beginAttempt: @Sendable () -> Bool
    // The attempt's whole body has left the client, so the server may run the statement.
    public let bodySent: @Sendable () -> Void

    public init(
        isStopped: @escaping @Sendable () -> Bool,
        beginAttempt: @escaping @Sendable () -> Bool,
        bodySent: @escaping @Sendable () -> Void
    ) {
        self.isStopped = isStopped
        self.beginAttempt = beginAttempt
        self.bodySent = bodySent
    }

    public static let unstoppable = BigQueryRequestSignals(isStopped: { false }, beginAttempt: { true }, bodySent: {})
}

public enum BigQueryStoppableRequest {
    // Runs `request` apart from the caller, since cancelling a sent request on the wire would lose the job reference its
    // answer carries. The caller's cancellation is Stop; an answer that arrives after Stop goes to `afterStop`.
    public static func value<Answer: Sendable>(
        grace: Duration,
        limit: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        request: @escaping @Sendable (BigQueryRequestSignals) async throws -> Answer,
        afterStop: @escaping @Sendable (Answer) async -> Void
    ) async throws -> Answer {
        let run = StoppableRun(grace: grace, limit: limit, clock: clock, request: request, afterStop: afterStop)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { caller in
                run.start(caller: caller)
            }
        } onCancel: {
            run.stop()
        }
    }
}

private final class StoppableRun<Answer: Sendable>: @unchecked Sendable {
    typealias Caller = CheckedContinuation<Answer, any Error>

    private struct Followup {
        var release: (Caller, Result<Answer, any Error>)?
        var cancel: [Task<Void, Never>] = []
        var handOver: Answer?

        func perform() {
            if case let (caller, result)? = release {
                caller.resume(with: result)
            }
            cancel.forEach { $0.cancel() }
        }
    }

    private let grace: Duration
    private let limit: Duration
    private let clock: any Clock<Duration>
    private let request: @Sendable (BigQueryRequestSignals) async throws -> Answer
    private let afterStop: @Sendable (Answer) async -> Void

    private let lock = NSLock()
    private var lifecycle = BigQueryStopLifecycle()
    private var caller: Caller?
    private var requestTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(
        grace: Duration,
        limit: Duration,
        clock: any Clock<Duration>,
        request: @escaping @Sendable (BigQueryRequestSignals) async throws -> Answer,
        afterStop: @escaping @Sendable (Answer) async -> Void
    ) {
        self.grace = grace
        self.limit = limit
        self.clock = clock
        self.request = request
        self.afterStop = afterStop
    }

    func start(caller waiting: Caller) {
        lock.withLock {
            caller = waiting
            return apply(.start, ended: nil)
        }.perform()
    }

    func stop() {
        lock.withLock { apply(.stop, ended: nil) }.perform()
    }

    private var signals: BigQueryRequestSignals {
        BigQueryRequestSignals(
            isStopped: { [self] in
                lock.withLock { lifecycle.isStopped }
            },
            beginAttempt: { [self] in
                let (followup, admitted) = lock.withLock {
                    (apply(.attemptStarted, ended: nil), !lifecycle.isStopped)
                }
                followup.perform()
                return admitted
            },
            bodySent: { [self] in
                lock.withLock { apply(.bodySent, ended: nil) }.perform()
            }
        )
    }

    private func runRequest() async {
        let result: Result<Answer, any Error>
        do {
            result = .success(try await request(signals))
        } catch {
            result = .failure(error)
        }
        let event: BigQueryStopLifecycle.Event
        switch result {
        case .success:
            event = .answer
        case .failure:
            event = .failure
        }
        let followup = lock.withLock { apply(event, ended: result) }
        followup.perform()
        if let answer = followup.handOver {
            await afterStop(answer)
        }
    }

    private func elapsed(_ event: BigQueryStopLifecycle.Event) {
        lock.withLock { apply(event, ended: nil) }.perform()
    }

    // Runs under `lock`; what touches the caller or another task waits for `Followup.perform`.
    private func apply(_ event: BigQueryStopLifecycle.Event, ended result: Result<Answer, any Error>?) -> Followup {
        var followup = Followup()
        for effect in lifecycle.handle(event) {
            switch effect {
            case .launchRequest:
                requestTask = Task { await self.runRequest() }
            case .releaseCaller(let outcome):
                guard let waiting = caller else { continue }
                caller = nil
                switch outcome {
                case .answer, .error:
                    followup.release = result.map { (waiting, $0) }
                case .cancelled:
                    followup.release = (waiting, .failure(CancellationError()))
                }
            case .armTimer:
                timer = clock.stopTimer(grace: grace, limit: limit) { [self] event in
                    elapsed(event)
                }
            case .cancelTimer:
                if let timer {
                    followup.cancel.append(timer)
                }
                timer = nil
            case .cancelRequest:
                if let requestTask {
                    followup.cancel.append(requestTask)
                }
            case .handOverAnswer:
                if case .success(let answer) = result {
                    followup.handOver = answer
                }
            }
        }
        if result != nil {
            requestTask = nil
        }
        return followup
    }
}

fileprivate extension Clock where Duration == Swift.Duration {
    // Both deadlines count from Stop, so a timer that resumes late does not push the limit back.
    func stopTimer(
        grace: Duration,
        limit: Duration,
        elapsed: @escaping @Sendable (BigQueryStopLifecycle.Event) -> Void
    ) -> Task<Void, Never> {
        let stoppedAt = now
        return Task {
            do {
                try await sleep(until: stoppedAt.advanced(by: grace), tolerance: nil)
            } catch {
                return
            }
            elapsed(.graceElapsed)
            do {
                try await sleep(until: stoppedAt.advanced(by: Swift.max(limit, grace)), tolerance: nil)
            } catch {
                return
            }
            elapsed(.limitElapsed)
        }
    }
}
