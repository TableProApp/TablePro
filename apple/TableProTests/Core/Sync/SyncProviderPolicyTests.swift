import Combine
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncProviderPolicyTests {
    @Test("No key leaves the person's switch as it is")
    func absentKeyKeepsTheSwitch() {
        let open = ManagedPolicySnapshot()

        #expect(SyncProviderPolicy.settledEnabled(true, under: open))
        #expect(!SyncProviderPolicy.settledEnabled(false, under: open))
        #expect(SyncProviderPolicy.iCloud(open) == .init(isAllowed: true, isLocked: false))
        #expect(SyncProviderPolicy.disableReason(open) == nil)
    }

    @Test("A profile that names only iCloud turns sync on as the person's switch would, and locks it")
    func forcedICloudTurnsSyncOn() {
        for list in [["icloud"], ["icloud", "tablepro-sync"]] {
            let forced = ManagedPolicySnapshot(personalSyncProvider: list)

            #expect(SyncProviderPolicy.settledEnabled(false, under: forced), "\(list)")
            #expect(SyncProviderPolicy.iCloud(forced) == .init(isAllowed: true, isLocked: true), "\(list)")
        }
    }

    @Test("iCloud taken away turns sync off and locks the switch, whichever key does it")
    func iCloudTakenAwayTurnsSyncOff() {
        let profiles = [
            ManagedPolicySnapshot(personalSyncProvider: ["off"]),
            ManagedPolicySnapshot(personalSyncProvider: ["tablepro-sync"]),
            ManagedPolicySnapshot(personalSyncProvider: []),
            ManagedPolicySnapshot(iCloudSyncAllowed: false),
            ManagedPolicySnapshot(personalSyncProvider: ["icloud"], iCloudSyncAllowed: false)
        ]
        for profile in profiles {
            #expect(!SyncProviderPolicy.settledEnabled(true, under: profile), "\(profile)")
            #expect(SyncProviderPolicy.iCloud(profile) == .init(isAllowed: false, isLocked: true), "\(profile)")
            #expect(SyncProviderPolicy.disableReason(profile) == .managedPolicy, "\(profile)")
        }
    }

    @Test("Off and iCloud both allowed leave the choice to the person")
    func bothAllowedLeaveTheChoice() {
        let both = ManagedPolicySnapshot(personalSyncProvider: ["off", "icloud"])

        #expect(SyncProviderPolicy.settledEnabled(true, under: both))
        #expect(!SyncProviderPolicy.settledEnabled(false, under: both))
        #expect(SyncProviderPolicy.iCloud(both) == .init(isAllowed: true, isLocked: false))
    }
}

@MainActor
struct SyncCoordinatorPolicyTests {
    private let environment: SyncTestEnvironment

    init() throws {
        environment = try SyncTestEnvironment(label: "sync-policy")
        var settings = SyncSettings.default
        settings.enabled = true
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
    }

    @Test("A profile that leaves iCloud out keeps sync off from launch, with the organization as the reason")
    func managedAtLaunch() async throws {
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = environment.makeCoordinator(transport: transport, policyGate: { .managedPolicy })

        coordinator.start()
        await coordinator.sync(.userRequest)
        coordinator.disableSync()

        #expect(coordinator.syncStatus == .disabled(.managedPolicy))
        #expect(await transport.pullCount == 0)
        #expect(await transport.pushCount == 0)
    }

    @Test("A profile that arrives during a run stops it at once: nothing more is downloaded or kept")
    func stopsARunInFlight() async throws {
        let gate = PolicyGate()
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = environment.makeCoordinator(transport: transport, policyGate: { gate.reason })
        // The first read of the zone comes before the run's upload and download.
        await transport.whileZoneIsRead {
            gate.reason = .managedPolicy
        }

        await coordinator.sync(.userRequest)

        #expect(gate.reason == .managedPolicy)
        #expect(await transport.pullCount == 0)
        #expect(await transport.pushCount == 0)
        #expect(coordinator.syncStatus == .disabled(.managedPolicy))
        #expect(coordinator.lastSyncDate == nil)
    }

    @Test("A run the organization stopped keeps nothing, even when iCloud is allowed again before it goes on")
    func stoppedRunStaysStoppedWhenAllowedAgain() async throws {
        let gate = PolicyGate()
        let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
        let coordinator = environment.makeCoordinator(transport: transport, policyGate: { gate.reason })
        await transport.whileZoneIsRead {
            guard !gate.fired else { return }
            gate.fired = true
            gate.reason = .managedPolicy
            coordinator.disableSync()
            gate.reason = nil
        }

        await coordinator.sync(.userRequest)

        #expect(gate.fired)
        #expect(await transport.pullCount == 0)
        #expect(await transport.pushCount == 0)
        #expect(coordinator.lastSyncDate == nil)
    }

    @Test("Allowed again, sync waits for the switch")
    func allowedAgainFollowsTheSwitch() async throws {
        let gate = PolicyGate()
        gate.reason = .managedPolicy
        let changes = PassthroughSubject<Void, Never>()
        var settings = SyncSettings.default
        settings.enabled = false
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        let coordinator = environment.makeCoordinator(
            transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID),
            policyGate: { gate.reason },
            policyChanges: changes.eraseToAnyPublisher()
        )
        coordinator.start()

        gate.reason = nil
        changes.send(())

        #expect(coordinator.syncStatus == .disabled(.userDisabled))
    }
}

@MainActor
private final class PolicyGate {
    var reason: DisableReason?
    var fired = false
}
