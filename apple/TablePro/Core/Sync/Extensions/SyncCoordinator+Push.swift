import Foundation
import TableProSyncTransport

extension SyncCoordinator {
    // CloudKit registers the device for its own notices, so the token goes nowhere.
    func pushRegistrationDidFinish(registered: Bool) {
        pushChannel.registrationDidFinish(registered: registered)
    }

    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard syncStatus.isEnabled, SyncPushSubscription.announcesChange(userInfo) else { return }
        pushChannel.noticeArrived()
        requestSync(.remoteChange)
    }

    var isPushLive: Bool {
        pushChannel.isLive
    }

    var activationHoldInterval: Duration {
        isPushLive ? Self.pushFallbackInterval : Self.activationInterval
    }
}
