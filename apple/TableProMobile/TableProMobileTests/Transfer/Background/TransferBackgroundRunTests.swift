import Foundation
import TableProTestSupport
import Testing
import UIKit
@testable import TableProMobile

@MainActor
private final class RecordingAsserter: BackgroundTaskAsserting {
    let identifier = UIBackgroundTaskIdentifier(rawValue: 11)
    private(set) var names: [String] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private var expirationHandler: (() -> Void)?

    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        names.append(name)
        self.expirationHandler = expirationHandler
        return identifier
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    func fireExpiration() {
        expirationHandler?()
    }
}

@MainActor
private final class FakeContinuedTask: ContinuedProcessingTask {
    let progress = Progress(totalUnitCount: 0)
    private(set) var titles: [(String, String)] = []
    private(set) var completions: [Bool] = []
    private var expiration: (@MainActor () -> Void)?

    func updateTitle(_ title: String, subtitle: String) {
        titles.append((title, subtitle))
    }

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }

    func onExpiration(_ handler: @escaping @MainActor () -> Void) {
        expiration = handler
    }

    func expire() {
        expiration?()
    }
}

@MainActor
private final class FakeScheduler: ContinuedProcessingScheduling {
    struct Refused: Error {}

    var refuses = false
    private(set) var identifiers: [String] = []
    private var launch: (@MainActor (any ContinuedProcessingTask) -> Void)?

    func submit(
        identifier: String,
        title: String,
        subtitle: String,
        launch: @escaping @MainActor (any ContinuedProcessingTask) -> Void
    ) throws {
        identifiers.append(identifier)
        if refuses { throw Refused() }
        self.launch = launch
    }

    func start(_ task: FakeContinuedTask) {
        launch?(task)
    }
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
private final class FakeHold: TransferHolding {
    private(set) var releases = 0

    func release() {
        releases += 1
    }
}

@MainActor
struct TransferBackgroundRunTests {
    @Test("A refused continued task leaves the run on the assertion, which ends with it")
    func submissionFailureFallsBackToTheAssertion() {
        let asserter = RecordingAsserter()
        let scheduler = FakeScheduler()
        scheduler.refuses = true
        let hold = FakeHold()
        let run = TransferBackgroundRun(title: "Export", asserter: asserter, scheduler: scheduler, hold: { hold })
        let expired = Counter()

        run.begin { expired.value += 1 }

        #expect(asserter.names == ["Export"])
        #expect(!run.isRunningContinuedTask)
        #expect(run.submittedIdentifier == nil)
        #expect(scheduler.identifiers.first?.hasPrefix("com.TablePro.TableProMobile.transfer.") == true)
        run.end(success: true)
        #expect(asserter.ended == [asserter.identifier])
        #expect(hold.releases == 1)
        #expect(expired.value == 0)
    }

    @Test("Each run asks for its own identifier, never one registered before")
    func identifiersAreUnique() {
        let scheduler = FakeScheduler()
        for _ in 0..<2 {
            let run = TransferBackgroundRun(title: "Import", asserter: RecordingAsserter(), scheduler: scheduler, hold: nil)
            run.begin {}
            run.end(success: true)
        }
        #expect(Set(scheduler.identifiers).count == 2)
    }

    @Test("When the assertion runs out with no continued task, the run is told once and the assertion ends")
    func assertionExpiryStopsTheRun() async throws {
        let asserter = RecordingAsserter()
        let run = TransferBackgroundRun(
            title: "Export", asserter: asserter, scheduler: nil, hold: nil, expiryGrace: .milliseconds(1)
        )
        let expired = Counter()
        run.begin { expired.value += 1 }

        asserter.fireExpiration()
        asserter.fireExpiration()

        #expect(expired.value == 1)
        try await waitUntil { asserter.ended == [asserter.identifier] }
        run.end(success: false)
        #expect(asserter.ended == [asserter.identifier])
    }

    @Test("A continued task carries the progress and title, completes once, and outlives the assertion")
    func continuedTaskMirrorsProgress() {
        let asserter = RecordingAsserter()
        let scheduler = FakeScheduler()
        let run = TransferBackgroundRun(title: "Export", asserter: asserter, scheduler: scheduler, hold: nil)
        let expired = Counter()
        run.begin { expired.value += 1 }
        let task = FakeContinuedTask()
        scheduler.start(task)

        var progress = TransferProgress(stage: .running)
        progress.completedUnits = 250
        progress.totalUnits = 1_000
        run.report(progress)

        #expect(run.isRunningContinuedTask)
        #expect(task.progress.fractionCompleted == 0.25)
        #expect(task.titles.last?.1 == TransferBackgroundRun.subtitle(for: progress))

        asserter.fireExpiration()
        #expect(expired.value == 0)
        #expect(asserter.ended == [asserter.identifier])

        run.end(success: true)
        run.end(success: false)
        #expect(task.completions == [true])
    }

    @Test("A progress with no total still moves the continued task forward")
    func indeterminateProgressStillAdvances() {
        let scheduler = FakeScheduler()
        let run = TransferBackgroundRun(title: "Export", asserter: RecordingAsserter(), scheduler: scheduler, hold: nil)
        run.begin {}
        let task = FakeContinuedTask()
        scheduler.start(task)

        var progress = TransferProgress(stage: .running)
        progress.completedUnits = 10
        run.report(progress)
        let first = task.progress.completedUnitCount
        progress.completedUnits = 20
        run.report(progress)

        #expect(task.progress.completedUnitCount > first)
        run.end(success: true)
    }

    @Test("The person cancelling the continued task stops the run")
    func continuedTaskExpiryStopsTheRun() {
        let scheduler = FakeScheduler()
        let run = TransferBackgroundRun(title: "Import", asserter: RecordingAsserter(), scheduler: scheduler, hold: nil)
        let expired = Counter()
        run.begin { expired.value += 1 }
        let task = FakeContinuedTask()
        scheduler.start(task)

        task.expire()
        run.end(success: false)

        #expect(expired.value == 1)
        #expect(task.completions == [false])
    }
}
