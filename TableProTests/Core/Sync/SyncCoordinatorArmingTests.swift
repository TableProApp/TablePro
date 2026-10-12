import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncCoordinatorArmingTests {
    private let environment: SyncTestEnvironment
    private let monitors = NetworkMonitorLog()

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-arming")
    }

    private func setSync(_ enabled: Bool) {
        var settings = SyncSettings.default
        settings.enabled = enabled
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
    }

    private func makeCoordinator(licensed: Bool = true) -> SyncCoordinator {
        environment.makeCoordinator(
            transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID),
            makeNetworkMonitor: monitors.make,
            licenseGate: { licensed ? nil : .licenseRequired }
        )
    }

    private var readableTypes: Set<String> {
        Set(SyncRecordType.verifiedInProduction.map(\.rawValue))
    }

    @Test("Sync off at launch starts no network monitor and leaves the sync token alone")
    func offAtLaunchArmsNothing() {
        setSync(false)
        let coordinator = makeCoordinator()

        coordinator.start()

        #expect(coordinator.syncStatus == .disabled(.userDisabled))
        #expect(monitors.made == 0)
        #expect(environment.metadata.adoptReadableRecordTypes(readableTypes), "Launch adopted record types for a sync that is off")
    }

    @Test("Sync switched on without a license that covers it arms nothing")
    func unlicensedArmsNothing() {
        setSync(true)
        let coordinator = makeCoordinator(licensed: false)

        coordinator.start()

        #expect(coordinator.syncStatus == .disabled(.licenseRequired))
        #expect(monitors.made == 0)
    }

    @Test("Sync on at launch starts the network monitor")
    func onAtLaunchArms() {
        setSync(true)
        let coordinator = makeCoordinator()

        coordinator.start()

        #expect(coordinator.syncStatus.isEnabled)
        #expect(monitors.made == 1)
        #expect(monitors.alive == 1)
    }

    @Test("Turning sync on arms, turning it off disarms, and turning it on again arms anew")
    func toggleArmsAndDisarms() {
        setSync(false)
        let coordinator = makeCoordinator()
        coordinator.start()

        setSync(true)
        coordinator.enableSync()
        #expect(monitors.made == 1)
        #expect(monitors.alive == 1)

        setSync(false)
        coordinator.disableSync()
        #expect(monitors.alive == 0, "The network monitor outlived sync")

        setSync(true)
        coordinator.enableSync()
        #expect(monitors.made == 2)
        #expect(monitors.alive == 1)
    }

    @Test("A sync turned on after launch adopts this build's record types")
    func turnedOnLaterAdoptsRecordTypes() {
        setSync(false)
        let coordinator = makeCoordinator()
        coordinator.start()

        setSync(true)
        coordinator.enableSync()

        #expect(!environment.metadata.adoptReadableRecordTypes(readableTypes))
    }
}

/// Hands out real monitors and holds them weakly, so a test sees whether the coordinator still
/// holds one.
private final class NetworkMonitorLog {
    private var monitors: [WeakMonitor] = []

    var made: Int { monitors.count }
    var alive: Int { monitors.filter { $0.monitor != nil }.count }

    func make() -> SyncNetworkMonitor? {
        let monitor = SyncNetworkMonitor()
        monitors.append(WeakMonitor(monitor: monitor))
        return monitor
    }

    private struct WeakMonitor {
        weak var monitor: SyncNetworkMonitor?
    }
}
