import CloudKit
import Foundation
import os

// Registration for CloudKit's change notices and the subscription that sends them. Nothing here runs while sync is off.
@MainActor
public final class SyncPushChannel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncPush")

    private let registrar: SyncPushRegistrar
    private let metadata: SyncMetadataStorage
    private var isRequested = false
    private var isRegistered = false
    private var missedNotice = false
    private var refusedAccount: String?
    public private(set) var noticesReceived = 0

    public init(registrar: SyncPushRegistrar, metadata: SyncMetadataStorage) {
        self.registrar = registrar
        self.metadata = metadata
    }

    public func register() {
        guard !isRequested else { return }
        isRequested = true
        registrar.register()
    }

    // Only a registration this process asked for is taken back, so a launch with sync off calls nothing.
    public func unregister() {
        isRegistered = false
        missedNotice = false
        guard isRequested else { return }
        isRequested = false
        registrar.unregister()
    }

    public func registrationDidFinish(registered: Bool) {
        guard isRequested else { return }
        isRegistered = registered
    }

    public func noticeArrived() {
        missedNotice = false
        noticesReceived += 1
    }

    // While notices arrive, a download they did not start finds nothing new. One that does, with no notice since
    // the last download began, means they stopped arriving. The subscription is saved again in case it is gone.
    public func activationFoundUnannouncedChanges(noticesSince count: Int) -> Bool {
        guard isLive, noticesReceived == count else { return false }
        missedNotice = true
        forgetSubscription()
        return true
    }

    public var isLive: Bool {
        guard isRegistered, !missedNotice, let account = metadata.lastAccountId else { return false }
        return metadata.subscribedAccountId == account
    }

    // A failed save never fails the run. One CloudKit refuses is not sent again for that account until the next launch.
    public func saveSubscriptionIfNeeded(_ save: () async throws -> Void) async {
        guard let account = metadata.lastAccountId,
              metadata.subscribedAccountId != account,
              refusedAccount != account else { return }
        do {
            try await save()
            metadata.subscribedAccountId = account
        } catch {
            Self.logger.error("Could not save the CloudKit change subscription: \(error.localizedDescription, privacy: .private)")
            // Only a fault of the build or the app version stays until relaunch; anything else is tried on the next run.
            switch SyncFailure(error) {
            case .blocked(.unavailable), .blocked(.appUpdateRequired):
                refusedAccount = account
            default:
                break
            }
        }
    }

    // Turning sync on, or finding TablePro's data removed from iCloud, saves the subscription again in case it is gone.
    public func forgetSubscription() {
        metadata.subscribedAccountId = nil
        refusedAccount = nil
    }
}
