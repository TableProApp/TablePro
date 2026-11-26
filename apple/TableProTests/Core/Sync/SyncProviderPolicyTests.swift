import Combine
import Foundation
@testable import TablePro
import TableProFFI
import TableProSyncTransport
import TableProTestSupport
import Testing

@MainActor
struct SyncProviderPolicyTests {
    @Test("No key leaves the person's provider as it is", arguments: SyncProviderSetting.allCases)
    func absentKeyKeepsTheProvider(provider: SyncProviderSetting) {
        let open = ManagedPolicySnapshot()

        #expect(SyncProviderPolicy.settledProvider(provider, under: open) == provider)
        #expect(SyncProviderPolicy.iCloud(open) == .init(isAllowed: true, isLocked: false))
        #expect(SyncProviderPolicy.disableReason(open) == nil)
        #expect(SyncProviderPolicy.choices(open).providers == [.off, .icloud, .tableproSync])
    }

    @Test("A profile that names only iCloud turns iCloud on as the person would, and locks it")
    func forcedICloudTurnsSyncOn() {
        let forced = ManagedPolicySnapshot(personalSyncProvider: ["icloud"])

        for provider in SyncProviderSetting.allCases {
            #expect(SyncProviderPolicy.settledProvider(provider, under: forced) == .iCloud, "\(provider)")
        }
        #expect(SyncProviderPolicy.iCloud(forced) == .init(isAllowed: true, isLocked: true))
    }

    @Test("A profile that names only TablePro Sync chooses it, and iCloud stops")
    func forcedTableProSync() {
        let forced = ManagedPolicySnapshot(personalSyncProvider: ["tablepro-sync"])

        for provider in SyncProviderSetting.allCases {
            #expect(SyncProviderPolicy.settledProvider(provider, under: forced) == .tableproSync, "\(provider)")
        }
        #expect(SyncProviderPolicy.iCloud(forced) == .init(isAllowed: false, isLocked: true))
        #expect(SyncProviderPolicy.disableReason(forced) == .managedPolicy)
    }

    @Test("iCloud taken away turns it off and leaves TablePro Sync where the profile allows it")
    func iCloudTakenAway() {
        let profiles = [
            ManagedPolicySnapshot(personalSyncProvider: ["off"]),
            ManagedPolicySnapshot(personalSyncProvider: []),
            ManagedPolicySnapshot(iCloudSyncAllowed: false),
            ManagedPolicySnapshot(personalSyncProvider: ["icloud"], iCloudSyncAllowed: false),
            ManagedPolicySnapshot(personalSyncProvider: ["off", "tablepro-sync"])
        ]
        for profile in profiles {
            #expect(SyncProviderPolicy.settledProvider(.iCloud, under: profile) == .off, "\(profile)")
            #expect(!SyncProviderPolicy.iCloud(profile).isAllowed, "\(profile)")
            #expect(SyncProviderPolicy.disableReason(profile) == .managedPolicy, "\(profile)")
        }
        let iCloudOff = ManagedPolicySnapshot(iCloudSyncAllowed: false)
        #expect(SyncProviderPolicy.settledProvider(.tableproSync, under: iCloudOff) == .tableproSync)
        #expect(SyncProviderPolicy.iCloud(iCloudOff) == .init(isAllowed: false, isLocked: false))
    }

    @Test("TablePro Sync taken away turns it off, and never moves the Mac to iCloud")
    func tableProSyncTakenAway() {
        let both = ManagedPolicySnapshot(personalSyncProvider: ["off", "icloud"])

        #expect(SyncProviderPolicy.settledProvider(.tableproSync, under: both) == .off)
        #expect(SyncProviderPolicy.settledProvider(.iCloud, under: both) == .iCloud)
        #expect(SyncProviderPolicy.iCloud(both) == .init(isAllowed: true, isLocked: false))
    }

    @Test("A profile whose list is empty leaves no provider, whatever was chosen")
    func emptyListLeavesNone() {
        let none = ManagedPolicySnapshot(personalSyncProvider: [])

        #expect(SyncProviderPolicy.choices(none).providers.isEmpty)
        #expect(SyncProviderPolicy.choices(none).locked)
        #expect(SyncProviderPolicy.settledProvider(.tableproSync, under: none) == .off)
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

    @Test("A stop followed at once by an allow still stops sync before it waits for the switch again")
    func stopThenAllowStillStops() async throws {
        let changes = PassthroughSubject<DisableReason?, Never>()
        var settings = SyncSettings.default
        settings.enabled = false
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        let coordinator = environment.makeCoordinator(
            transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID),
            policyChanges: changes.eraseToAnyPublisher()
        )
        coordinator.start()
        let seen = StatusLog()
        let watching = coordinator.$syncStatus.sink { seen.statuses.append($0) }

        changes.send(.managedPolicy)
        changes.send(nil)
        try await waitUntil { seen.statuses.count >= 3 && seen.statuses.last == .disabled(.userDisabled) }
        watching.cancel()

        #expect(seen.statuses.contains(.disabled(.managedPolicy)))
    }

    @Test("Allowed again, sync waits for the switch")
    func allowedAgainFollowsTheSwitch() async throws {
        let gate = PolicyGate()
        gate.reason = .managedPolicy
        let changes = PassthroughSubject<DisableReason?, Never>()
        var settings = SyncSettings.default
        settings.enabled = false
        AppSettingsStorage(userDefaults: environment.defaults).saveSync(settings)
        let coordinator = environment.makeCoordinator(
            transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID),
            policyGate: { gate.reason },
            policyChanges: changes.eraseToAnyPublisher()
        )
        coordinator.start()

        #expect(coordinator.syncStatus == .disabled(.managedPolicy))
        gate.reason = nil
        changes.send(nil)

        try await waitUntil { coordinator.syncStatus == .disabled(.userDisabled) }
    }
}

@MainActor
private final class PolicyGate {
    var reason: DisableReason?
    var fired = false
}

@MainActor
private final class StatusLog {
    var statuses: [SyncStatus] = []
}
