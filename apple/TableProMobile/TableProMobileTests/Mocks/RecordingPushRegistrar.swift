@testable import TableProMobile
import TableProSyncTransport

@MainActor
final class RecordingPushRegistrar {
    private(set) var registrations = 0
    private(set) var unregistrations = 0

    var registrar: SyncPushRegistrar {
        SyncPushRegistrar(
            register: { [weak self] in self?.registrations += 1 },
            unregister: { [weak self] in self?.unregistrations += 1 }
        )
    }
}

extension SyncPushRegistrar {
    static let inert = SyncPushRegistrar(register: {}, unregister: {})
}
