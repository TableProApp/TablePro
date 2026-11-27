import AppKit
import TableProSyncTransport

extension SyncPushRegistrar {
    static let live = SyncPushRegistrar(
        register: { NSApplication.shared.registerForRemoteNotifications() },
        unregister: { NSApplication.shared.unregisterForRemoteNotifications() }
    )
}
