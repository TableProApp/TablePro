import TableProSyncTransport
import UIKit

extension SyncPushRegistrar {
    static let live = SyncPushRegistrar(
        register: { UIApplication.shared.registerForRemoteNotifications() },
        unregister: { UIApplication.shared.unregisterForRemoteNotifications() }
    )
}
