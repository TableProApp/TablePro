import os
import TableProDatabase
import UIKit

@MainActor
protocol BackgroundTaskAsserting {
    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTaskAsserting {
    func beginBackgroundTask(name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }
}

@MainActor
final class BackgroundReleaseCoordinator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "BackgroundRelease")
    private static let taskName = "Release database files"

    private let connectionManager: ConnectionManager
    private let asserter: BackgroundTaskAsserting
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
    private var isPreparedForSuspension = false
    private var releasesInFlight = 0

    init(connectionManager: ConnectionManager, asserter: BackgroundTaskAsserting = UIApplication.shared) {
        self.connectionManager = connectionManager
        self.asserter = asserter
    }

    func prepareForSuspension() {
        isPreparedForSuspension = true
        syncAssertion()
    }

    func cancelPreparation() {
        isPreparedForSuspension = false
        syncAssertion()
    }

    func releaseForSuspension() async {
        isPreparedForSuspension = false
        guard connectionManager.hasSuspensionBlockingResources else {
            syncAssertion()
            return
        }
        beginAssertion()
        releasesInFlight += 1
        await connectionManager.releaseSuspensionBlockingResources()
        releasesInFlight -= 1
        syncAssertion()
    }

    private var needsAssertion: Bool {
        if releasesInFlight > 0 { return true }
        return isPreparedForSuspension && connectionManager.hasSuspensionBlockingResources
    }

    private func syncAssertion() {
        guard needsAssertion else {
            endAssertion(expired: false)
            return
        }
        beginAssertion()
    }

    private func beginAssertion() {
        guard taskIdentifier == .invalid else { return }
        taskIdentifier = asserter.beginBackgroundTask(name: Self.taskName) { [weak self] in
            self?.endAssertion(expired: true)
        }
    }

    private func endAssertion(expired: Bool) {
        guard taskIdentifier != .invalid else { return }
        if expired {
            Self.logger.warning("Background time expired before database files were released")
        }
        asserter.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
    }
}
