import AppKit
import Combine
import UserNotifications

// Reads only, again on each activation since System Settings can change it meanwhile; NotificationAuthorization is the one requester.
@MainActor
internal final class NotificationPermissionMonitor: ObservableObject {
    @Published internal private(set) var status: UNAuthorizationStatus

    private let authorization: NotificationAuthorization
    private var activation: AnyCancellable?
    private var generation = 0

    internal init(
        authorization: NotificationAuthorization = .shared,
        center: NotificationCenter = .default
    ) {
        self.authorization = authorization
        status = authorization.status
        activation = center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    // A slower earlier read never overwrites a newer one.
    internal func refresh() async {
        generation += 1
        let current = generation
        let latest = await authorization.refresh()
        guard current == generation else { return }
        status = latest
    }
}
