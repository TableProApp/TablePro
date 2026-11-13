import CloudKit
import Foundation

public enum SyncPushSubscription {
    public static let id = "TableProSyncChanges"

    // A database subscription outlives a deleted or purged zone and announces the zone coming back.
    public static func make() -> CKDatabaseSubscription {
        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let notificationInfo = CKSubscription.NotificationInfo()
        // Silent: no alert, badge or sound, so the system asks the person nothing.
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        return subscription
    }

    // The payload is only a signal: it starts the same download an activation does, and nothing in it is read.
    public static func announcesChange(
        _ userInfo: [AnyHashable: Any],
        containerIdentifier: String = CloudKitSyncEngine.defaultContainerID
    ) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKDatabaseNotification else {
            return false
        }
        return notification.subscriptionID == id && notification.containerIdentifier == containerIdentifier
    }
}
