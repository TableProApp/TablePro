import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
final class AppRelauncherFixture {
    static let bundleURL = URL(fileURLWithPath: "/Applications/TablePro.app")

    enum QuitOutcome {
        case committed
        case cancelledByTheApp
    }

    let suite: EphemeralDefaults
    var documentsReviewed = true
    var stoppingWorkApproved = true
    var commits: [SessionTransactionTracker.Hold] = []
    var commitSucceeds = true
    var commitGate: AsyncGate?
    private(set) var commitCalls = 0
    private(set) var workQuestions = 0
    private(set) var approvedWhenQuitting: [Bool] = []
    var hasPendingUpdate = false
    var quitOutcome = QuitOutcome.committed
    var reopenFails = false
    private(set) var installs = 0
    private(set) var terminations = 0
    // Runs that went through the next run loop turn rather than inside the commit's task.
    private(set) var deferredRuns = 0
    private(set) var reopens: [(pid: pid_t, bundleURL: URL)] = []
    private(set) var relauncher: AppRelauncher!

    init() throws {
        suite = try EphemeralDefaults()
        relauncher = AppRelauncher(
            defaults: suite.defaults,
            approveStoppingWork: { [unowned self] in
                workQuestions += 1
                return stoppingWorkApproved ? QuitPlan(commits: commits, work: []) : nil
            },
            commitBeforeQuitting: { [unowned self] _ in
                commitCalls += 1
                await commitGate?.wait()
                return commitSucceeds
            },
            reviewUnsavedDocuments: { [unowned self] completion in completion(documentsReviewed) },
            installPendingUpdate: { [unowned self] in
                guard hasPendingUpdate else { return false }
                installs += 1
                return true
            },
            terminate: { [unowned self] in
                terminations += 1
                approvedWhenQuitting.append(relauncher.hasApprovedRunningWork)
                switch quitOutcome {
                case .committed:
                    relauncher.applicationWillTerminate(processIdentifier: 42, bundleURL: Self.bundleURL)
                case .cancelledByTheApp:
                    relauncher.terminationWasCancelled()
                }
            },
            performOutsideTask: { [unowned self] body in
                deferredRuns += 1
                body()
            },
            reopenAfterExit: { [unowned self] pid, url in
                if reopenFails { throw CocoaError(.executableLoad) }
                reopens.append((pid, url))
            }
        )
    }

    var reopenRequested: Bool {
        suite.defaults.bool(forKey: PreferenceKeys.reopenSessionAfterRelaunch.name)
    }
}

@MainActor
struct AppRelauncherTests {
    @Test("Declining to stop running work keeps the app running and asks nothing else")
    func decliningRunningWorkStopsTheRelaunch() throws {
        let fixture = try AppRelauncherFixture()
        fixture.stoppingWorkApproved = false

        fixture.relauncher.relaunch()

        #expect(fixture.workQuestions == 1)
        #expect(fixture.terminations == 0)
        #expect(fixture.installs == 0)
        #expect(!fixture.relauncher.isRelaunchPending)
    }

    @Test("The quit a relaunch starts already has its answer about running work")
    func quitAfterARelaunchDoesNotAskAgain() throws {
        let fixture = try AppRelauncherFixture()

        fixture.relauncher.relaunch()

        #expect(fixture.workQuestions == 1)
        #expect(fixture.approvedWhenQuitting == [true])
    }

    @Test("A relaunch Sparkle took over and then dropped stops covering later quits")
    func abortedSparkleRelaunchForgetsItsApproval() throws {
        let fixture = try AppRelauncherFixture()
        fixture.hasPendingUpdate = true

        fixture.relauncher.relaunch()
        #expect(fixture.relauncher.hasApprovedRunningWork)

        fixture.relauncher.terminationWasCancelled()
        #expect(!fixture.relauncher.hasApprovedRunningWork)
    }

    @Test("Running work is asked about after the documents are reviewed, never when the review is cancelled")
    func cancelledDocumentReviewAsksNothingAboutWork() throws {
        let fixture = try AppRelauncherFixture()
        fixture.documentsReviewed = false

        fixture.relauncher.relaunch()

        #expect(fixture.workQuestions == 0)
        #expect(fixture.terminations == 0)
    }

    @Test("Without an update, the app quits and reopens once the quit is committed")
    func plainRelaunchReopensAfterExit() throws {
        let fixture = try AppRelauncherFixture()

        fixture.relauncher.relaunch()

        #expect(fixture.terminations == 1)
        #expect(fixture.reopens.count == 1)
        #expect(fixture.reopens.first?.pid == 42)
        #expect(fixture.reopens.first?.bundleURL == AppRelauncherFixture.bundleURL)
        #expect(fixture.reopenRequested)
        #expect(!fixture.relauncher.isRelaunchPending)
    }

    @Test("A downloaded update relaunches through Sparkle, which reopens the app itself")
    func pendingUpdateGoesThroughSparkle() throws {
        let fixture = try AppRelauncherFixture()
        fixture.hasPendingUpdate = true

        fixture.relauncher.relaunch()
        #expect(fixture.installs == 1)
        #expect(fixture.terminations == 0)
        #expect(!fixture.reopenRequested, "nothing is written until the quit is committed")

        fixture.relauncher.applicationWillTerminate(processIdentifier: 42, bundleURL: AppRelauncherFixture.bundleURL)
        #expect(fixture.reopens.isEmpty)
        #expect(fixture.reopenRequested)
    }

    @Test("Cancelling the unsaved-documents review stops the relaunch before anything quits")
    func documentReviewCancelStopsTheRelaunch() throws {
        let fixture = try AppRelauncherFixture()
        fixture.documentsReviewed = false

        fixture.relauncher.relaunch()
        fixture.relauncher.applicationWillTerminate(processIdentifier: 42, bundleURL: AppRelauncherFixture.bundleURL)

        #expect(fixture.terminations == 0)
        #expect(fixture.installs == 0)
        #expect(fixture.reopens.isEmpty)
        #expect(!fixture.reopenRequested)
    }

    @Test("A quit the app cancels forgets the relaunch, so a later Quit stays a quit")
    func cancelledQuitForgetsTheRelaunch() throws {
        let fixture = try AppRelauncherFixture()
        fixture.quitOutcome = .cancelledByTheApp

        fixture.relauncher.relaunch()
        fixture.relauncher.applicationWillTerminate(processIdentifier: 42, bundleURL: AppRelauncherFixture.bundleURL)

        #expect(fixture.terminations == 1)
        #expect(fixture.reopens.isEmpty)
        #expect(!fixture.reopenRequested)
    }

    @Test("A cancelled Sparkle relaunch forgets the reopen as well")
    func cancelledSparkleQuitForgetsTheReopen() throws {
        let fixture = try AppRelauncherFixture()
        fixture.hasPendingUpdate = true

        fixture.relauncher.relaunch()
        fixture.relauncher.terminationWasCancelled()
        fixture.relauncher.applicationWillTerminate(processIdentifier: 42, bundleURL: AppRelauncherFixture.bundleURL)

        #expect(!fixture.reopenRequested)
    }

    @Test("An ordinary quit never reopens")
    func ordinaryQuitDoesNotReopen() throws {
        let fixture = try AppRelauncherFixture()

        fixture.relauncher.applicationWillTerminate(processIdentifier: 42, bundleURL: AppRelauncherFixture.bundleURL)

        #expect(fixture.reopens.isEmpty)
        #expect(!fixture.reopenRequested)
    }

    @Test("A reopen that cannot be scheduled leaves no request for the next launch")
    func failedReopenLeavesNoRequest() throws {
        let fixture = try AppRelauncherFixture()
        fixture.reopenFails = true

        fixture.relauncher.relaunch()

        #expect(!fixture.reopenRequested)
    }

    @Test("With nothing to commit, the relaunch quits at once")
    func noCommitQuitsAtOnce() throws {
        let fixture = try AppRelauncherFixture()

        fixture.relauncher.relaunch()

        #expect(fixture.commitCalls == 0)
        #expect(fixture.relauncher.pendingCommit == nil)
        #expect(fixture.deferredRuns == 0)
        #expect(fixture.terminations == 1)
    }

    // The quit a relaunch starts asks nothing, so a transaction it would end is committed first.
    @Test("With an open transaction to commit, the relaunch quits only after the commit, outside its task")
    func quitsOnlyAfterTheCommit() async throws {
        let fixture = try AppRelauncherFixture()
        let gate = AsyncGate()
        fixture.commits = [Self.hold()]
        fixture.commitGate = gate

        fixture.relauncher.relaunch()
        let commit = try #require(fixture.relauncher.pendingCommit)
        await gate.arrived(1)

        #expect(fixture.terminations == 0)
        #expect(!fixture.relauncher.isRelaunchPending)

        await gate.open()
        await commit.value

        #expect(fixture.commitCalls == 1)
        #expect(fixture.deferredRuns == 1)
        #expect(fixture.terminations == 1)
        #expect(fixture.reopens.count == 1)
        #expect(fixture.relauncher.pendingCommit == nil)
    }

    @Test("Leaving a sign-in asks everything first, runs its work only then, and quits from the run loop")
    func signOutRelaunchAsksFirstAndQuitsOutsideItsTask() async throws {
        for refusal in ["none", "documents", "running work", "commit"] {
            let fixture = try AppRelauncherFixture()
            fixture.documentsReviewed = refusal != "documents"
            fixture.stoppingWorkApproved = refusal != "running work"
            if refusal == "commit" {
                fixture.commits = [Self.hold()]
                fixture.commitSucceeds = false
            }
            var worked = 0
            var cancelled = 0

            fixture.relauncher.relaunch(after: { worked += 1 }, ifCancelled: { cancelled += 1 })
            await fixture.relauncher.pendingCommit?.value

            if refusal == "none" {
                #expect(worked == 1)
                #expect(cancelled == 0)
                #expect(fixture.deferredRuns == 1, "The quit starts from the run loop, never inside the task")
                #expect(fixture.terminations == 1)
                #expect(fixture.reopens.count == 1)
            } else {
                #expect(worked == 0, "\(refusal)")
                #expect(cancelled == 1, "\(refusal)")
                #expect(fixture.terminations == 0, "\(refusal)")
            }
        }
    }

    @Test("With nothing to save, the quit a sign-out starts runs from the run loop and finishes")
    func signOutQuitCompletesWithNothingToSave() async throws {
        let suite = try EphemeralDefaults()
        let quit = TerminateLaterQuit()
        let relauncher = AppRelauncher(
            defaults: suite.defaults,
            approveStoppingWork: { QuitPlan(commits: [], work: []) },
            commitBeforeQuitting: { _ in true },
            reviewUnsavedDocuments: { $0(true) },
            installPendingUpdate: { false },
            terminate: { quit.waitForReply() },
            reopenAfterExit: { _, _ in }
        )

        relauncher.relaunch(after: {}, ifCancelled: {})
        await relauncher.pendingCommit?.value
        try await waitUntil { quit.isFinished }

        #expect(quit.replied)
    }

    @Test("Sparkle takes over only after the commit, outside its task")
    func sparkleInstallsAfterTheCommit() async throws {
        let fixture = try AppRelauncherFixture()
        fixture.commits = [Self.hold()]
        fixture.hasPendingUpdate = true

        fixture.relauncher.relaunch()
        let commit = try #require(fixture.relauncher.pendingCommit)
        await commit.value

        #expect(fixture.deferredRuns == 1)
        #expect(fixture.installs == 1)
        #expect(fixture.relauncher.isRelaunchPending)
    }

    @Test("A commit that fails or is cancelled stops the relaunch, and a later quit stays a quit")
    func failedCommitStopsTheRelaunch() async throws {
        let fixture = try AppRelauncherFixture()
        fixture.commits = [Self.hold()]
        fixture.commitSucceeds = false
        fixture.hasPendingUpdate = true

        fixture.relauncher.relaunch()
        let commit = try #require(fixture.relauncher.pendingCommit)
        await commit.value

        #expect(fixture.commitCalls == 1)
        #expect(fixture.deferredRuns == 0)
        #expect(fixture.installs == 0)
        #expect(fixture.terminations == 0)
        #expect(!fixture.relauncher.isRelaunchPending)
        #expect(!fixture.relauncher.hasApprovedRunningWork)
        #expect(fixture.relauncher.pendingCommit == nil)
    }

    @Test("A second relaunch while the commit runs asks nothing again")
    func relaunchDuringTheCommitIsIgnored() async throws {
        let fixture = try AppRelauncherFixture()
        let gate = AsyncGate()
        fixture.commits = [Self.hold()]
        fixture.commitGate = gate

        fixture.relauncher.relaunch()
        let commit = try #require(fixture.relauncher.pendingCommit)
        await gate.arrived(1)
        fixture.relauncher.relaunch()
        await gate.open()
        await commit.value

        #expect(fixture.workQuestions == 1)
        #expect(fixture.commitCalls == 1)
        #expect(fixture.terminations == 1)
    }

    private static func hold() -> SessionTransactionTracker.Hold {
        SessionTransactionTracker.Hold(key: .init(connectionId: UUID(), lane: nil), state: .open, revision: 0)
    }

    @Test("The next launch reads the reopen request once")
    func reopenRequestIsReadOnce() throws {
        let fixture = try AppRelauncherFixture()
        fixture.relauncher.relaunch()

        #expect(AppRelauncher.consumeReopenRequest(in: fixture.suite.defaults))
        #expect(!AppRelauncher.consumeReopenRequest(in: fixture.suite.defaults))
    }
}

// NSApp.terminate answered with .terminateLater: it runs the run loop until the app delegate's reply task has run.
@MainActor
final class TerminateLaterQuit {
    private(set) var replied = false
    private(set) var isFinished = false

    func waitForReply() {
        Task { @MainActor in self.replied = true }
        let deadline = Date().addingTimeInterval(2)
        while !replied, Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
        isFinished = true
    }
}
