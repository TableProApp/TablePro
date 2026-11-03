import Foundation
@testable import TablePro
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
    private(set) var workQuestions = 0
    private(set) var approvedWhenQuitting: [Bool] = []
    var hasPendingUpdate = false
    var quitOutcome = QuitOutcome.committed
    var reopenFails = false
    private(set) var installs = 0
    private(set) var terminations = 0
    private(set) var reopens: [(pid: pid_t, bundleURL: URL)] = []
    private(set) var relauncher: AppRelauncher!

    init() throws {
        suite = try EphemeralDefaults()
        relauncher = AppRelauncher(
            defaults: suite.defaults,
            approveStoppingWork: { [unowned self] in
                workQuestions += 1
                return stoppingWorkApproved
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

    @Test("The next launch reads the reopen request once")
    func reopenRequestIsReadOnce() throws {
        let fixture = try AppRelauncherFixture()
        fixture.relauncher.relaunch()

        #expect(AppRelauncher.consumeReopenRequest(in: fixture.suite.defaults))
        #expect(!AppRelauncher.consumeReopenRequest(in: fixture.suite.defaults))
    }
}
