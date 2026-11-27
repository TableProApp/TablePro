import BackgroundTasks
import Foundation
import os
import TableProDatabase
import TableProLogRedaction
import UIKit

// Keeps the connection a transfer runs on out of the suspension release while the transfer runs.
@MainActor
protocol TransferHolding: AnyObject {
    func release()
}

extension TransferHold: TransferHolding {}

@MainActor
protocol ContinuedProcessingTask: AnyObject {
    var progress: Progress { get }
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
    func onExpiration(_ handler: @escaping @MainActor () -> Void)
}

@MainActor
protocol ContinuedProcessingScheduling: AnyObject {
    // Registers `identifier` and submits a request for it; `launch` runs once the system starts the task.
    func submit(
        identifier: String,
        title: String,
        subtitle: String,
        launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void
    ) throws
}

// A long export or import keeps running when the user leaves the app: a `beginBackgroundTask` assertion on every
// release, and from iOS 26 a continued processing task the system shows with its progress. A run that cannot get the
// continued task carries on under the assertion alone.
@MainActor
final class TransferBackgroundRun {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TransferBackgroundRun")
    static let identifierPrefix = "com.TablePro.TableProMobile.transfer."

    private let title: String
    private let asserter: any BackgroundTaskAsserting
    private let scheduler: (any ContinuedProcessingScheduling)?
    private let holdProvider: (@MainActor () -> (any TransferHolding)?)?
    private let expiryGrace: Duration

    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var hold: (any TransferHolding)?
    private var continuedTask: (any ContinuedProcessingTask)?
    private var onExpiration: (@MainActor () -> Void)?
    private var hasBegun = false
    private var hasEnded = false
    private var hasExpired = false
    private var subtitle = ""
    private(set) var submittedIdentifier: String?

    init(
        title: String,
        asserter: any BackgroundTaskAsserting,
        scheduler: (any ContinuedProcessingScheduling)?,
        hold: (@MainActor () -> (any TransferHolding)?)?,
        expiryGrace: Duration = .seconds(2)
    ) {
        self.title = title
        self.asserter = asserter
        self.scheduler = scheduler
        self.holdProvider = hold
        self.expiryGrace = expiryGrace
    }

    convenience init(title: String, connectionManager: ConnectionManager, connectionId: UUID) {
        self.init(
            title: title,
            asserter: UIApplication.shared,
            scheduler: Self.systemScheduler(),
            hold: { connectionManager.holdForTransfer(connectionId) }
        )
    }

    static func systemScheduler() -> (any ContinuedProcessingScheduling)? {
        if #available(iOS 26.0, *) {
            return SystemContinuedProcessingScheduler()
        }
        return nil
    }

    var isRunningContinuedTask: Bool { continuedTask != nil }

    // Started while the app is in front, from the user's tap, which is when Apple requires a continued task to begin.
    func begin(onExpiration: @escaping @MainActor () -> Void) {
        guard !hasBegun else { return }
        hasBegun = true
        self.onExpiration = onExpiration
        hold = holdProvider?()
        assertion = asserter.beginBackgroundTask(name: title) { [weak self] in
            self?.assertionExpired()
        }
        submitContinuedTask()
    }

    func report(_ progress: TransferProgress) {
        guard let continuedTask, !hasEnded else { return }
        let mirrored = continuedTask.progress
        if let fraction = progress.fractionCompleted {
            mirrored.totalUnitCount = 1_000
            mirrored.completedUnitCount = Int64(fraction * 1_000)
        } else {
            // No total: the count still moves, which is what keeps the scheduler from calling the task stalled.
            mirrored.totalUnitCount = Int64(progress.completedUnits + 1)
            mirrored.completedUnitCount = Int64(progress.completedUnits)
        }
        let line = Self.subtitle(for: progress)
        guard line != subtitle else { return }
        subtitle = line
        continuedTask.updateTitle(title, subtitle: line)
    }

    func end(success: Bool) {
        guard hasBegun, !hasEnded else { return }
        hasEnded = true
        continuedTask?.setTaskCompleted(success: success)
        continuedTask = nil
        hold?.release()
        hold = nil
        endAssertion()
    }

    static func subtitle(for progress: TransferProgress) -> String {
        if let status = progress.status, !status.isEmpty { return status }
        switch progress.unit {
        case .rows:
            guard let total = progress.totalUnits else {
                return String(format: String(localized: "%@ rows"), progress.completedUnits.formatted())
            }
            return String(
                format: String(localized: "%1$@ of %2$@ rows"), progress.completedUnits.formatted(), total.formatted()
            )
        case .statements:
            guard let total = progress.totalUnits else {
                return String(format: String(localized: "%@ statements"), progress.completedUnits.formatted())
            }
            return String(
                format: String(localized: "%1$@ of %2$@ statements"),
                progress.completedUnits.formatted(),
                total.formatted()
            )
        }
    }

    // MARK: - Private

    private func submitContinuedTask() {
        guard let scheduler else { return }
        let identifier = Self.identifierPrefix + UUID().uuidString
        do {
            try scheduler.submit(identifier: identifier, title: title, subtitle: "") { [weak self] task in
                self?.adopt(task)
            }
            submittedIdentifier = identifier
        } catch {
            // Apple's guidance: a continued task that does not start leaves the work running on the assertion.
            Self.logger.info("Transfer runs without a continued task: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func adopt(_ task: any ContinuedProcessingTask) {
        guard !hasEnded else {
            task.setTaskCompleted(success: true)
            return
        }
        continuedTask = task
        task.onExpiration { [weak self] in
            self?.continuedTaskExpired()
        }
    }

    // The person cancelled from the system's progress UI, or the system needs the resources back.
    private func continuedTaskExpired() {
        expire()
    }

    // While a continued task runs, the app keeps running past the assertion; without one, the run must stop now.
    private func assertionExpired() {
        guard continuedTask == nil else {
            endAssertion()
            return
        }
        expire()
        let grace = expiryGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.endAssertion()
        }
    }

    private func expire() {
        guard !hasExpired, !hasEnded else { return }
        hasExpired = true
        Self.logger.warning("Background time for a transfer ran out; the transfer stops")
        onExpiration?()
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        asserter.endBackgroundTask(assertion)
        assertion = .invalid
    }
}

@available(iOS 26.0, *)
@MainActor
final class SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    nonisolated enum SubmissionError: Error {
        case registrationRefused
    }

    // Registered for the job's own identifier right before it is submitted: a handler on the wildcard is refused, and a
    // second registration of one identifier kills the app (BGTaskScheduler.h). The closures are `@Sendable` and hop to
    // the main actor themselves, so the scheduler's queue never trips the main-actor check (critic B1).
    func submit(
        identifier: String,
        title: String,
        subtitle: String,
        launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void
    ) throws {
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { @Sendable task in
            let box = UncheckedTask(task)
            Task { @MainActor in
                guard let continued = box.task as? BGContinuedProcessingTask else {
                    box.task.setTaskCompleted(success: false)
                    return
                }
                launch(SystemContinuedProcessingTask(continued))
            }
        }
        guard registered else { throw SubmissionError.registrationRefused }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }
}

@available(iOS 26.0, *)
@MainActor
final class SystemContinuedProcessingTask: ContinuedProcessingTask {
    private let task: BGContinuedProcessingTask

    init(_ task: BGContinuedProcessingTask) {
        self.task = task
    }

    var progress: Progress { task.progress }

    func updateTitle(_ title: String, subtitle: String) {
        task.updateTitle(title, subtitle: subtitle)
    }

    func setTaskCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }

    func onExpiration(_ handler: @escaping @MainActor () -> Void) {
        task.expirationHandler = { @Sendable in
            Task { @MainActor in handler() }
        }
    }
}

// A BGTask crosses from the scheduler's callback to the main actor once, and is used only there.
nonisolated private final class UncheckedTask: @unchecked Sendable {
    let task: BGTask

    init(_ task: BGTask) {
        self.task = task
    }
}
