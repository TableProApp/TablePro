//
//  SyncProviderPolicy.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI
import TableProSyncTransport

// Which providers a configuration profile leaves this Mac, by the core's rule (core ADR 0055, PersonalSyncProvider).
// Until TablePro Sync ships the Mac offers Off and iCloud, and the iCloud switch is its picker.
@MainActor
internal final class SyncProviderPolicy {
    static let shared = SyncProviderPolicy()

    nonisolated static let offered: [SyncProviderTag] = [.off, .icloud]

    private var subscription: AnyCancellable?

    // Keeps the switch on the provider the values leave this Mac, now and whenever the values or the switch change,
    // so a settings import or a reset cannot turn on a provider the profile left out. The write waits a turn, since
    // the setting is published before it is stored.
    func start(center: ManagedPolicyCenter = .shared, settings: AppSettingsManager = .shared) {
        guard subscription == nil else { return }
        subscription = center.$snapshot
            .combineLatest(settings.syncSlice.publisher.map(\.enabled).removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak settings] snapshot, _ in
                guard let settings else { return }
                let enabled = Self.settledEnabled(settings.sync.enabled, under: snapshot)
                guard enabled != settings.sync.enabled else { return }
                settings.sync.enabled = enabled
            }
    }

    struct ICloudStanding: Equatable, Sendable {
        let isAllowed: Bool
        // One choice or none: the switch is the organization's.
        let isLocked: Bool
    }

    nonisolated static func iCloud(_ snapshot: ManagedPolicySnapshot) -> ICloudStanding {
        let choices = personalSyncChoices(policy: snapshot.coreArgument, offered: offered)
        return ICloudStanding(isAllowed: choices.providers.contains(.icloud), isLocked: choices.locked)
    }

    nonisolated static func disableReason(_ snapshot: ManagedPolicySnapshot) -> DisableReason? {
        iCloud(snapshot).isAllowed ? nil : .managedPolicy
    }

    // A forced iCloud turns the switch on as the person would, and iCloud taken away turns it off; with a choice left,
    // the person's switch stands. A server's answer never moves it: no server takes this Mac's personal data yet.
    nonisolated static func settledEnabled(_ enabled: Bool, under snapshot: ManagedPolicySnapshot) -> Bool {
        settledSyncProvider(
            policy: snapshot.coreArgument,
            offered: offered,
            current: enabled ? .icloud : .off,
            tableproSyncAvailable: false
        ) == .icloud
    }
}

extension ManagedPolicySnapshot {
    // The Mac reads no update-check key: Sparkle's own keys govern its feed.
    var coreArgument: ManagedPolicyArg {
        .read(values: ManagedPolicyValues(
            accountServerUrl: accountServerURL,
            allowOtherAccountServers: allowOtherAccountServers,
            personalSyncProvider: personalSyncProvider,
            usageDataAllowed: usageDataAllowed,
            pluginCatalogAllowed: pluginCatalogAllowed,
            updateChecksAllowed: nil,
            icloudSyncAllowed: iCloudSyncAllowed
        ))
    }
}
