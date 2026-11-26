//
//  SyncProviderPolicy.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI
import TableProSyncTransport

// Which providers a configuration profile leaves this Mac, by the core's rule (core ADR 0055, PersonalSyncProvider).
@MainActor
internal final class SyncProviderPolicy {
    static let shared = SyncProviderPolicy()

    nonisolated static let offered: [SyncProviderTag] = [.off, .icloud, .tableproSync]

    private var subscription: AnyCancellable?

    // Keeps the provider on one the values leave this Mac, now and whenever the values or the provider change, so a
    // settings import or a reset cannot choose a provider the profile left out. The write waits a turn, since the
    // setting is published before it is stored.
    func start(center: ManagedPolicyCenter = .shared, settings: AppSettingsManager = .shared) {
        guard subscription == nil else { return }
        subscription = center.$snapshot
            .combineLatest(settings.syncSlice.publisher.map(\.provider).removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak settings] snapshot, _ in
                guard let settings else { return }
                let provider = Self.settledProvider(settings.sync.provider, under: snapshot)
                guard provider != settings.sync.provider else { return }
                settings.sync.provider = provider
            }
    }

    struct ICloudStanding: Equatable, Sendable {
        let isAllowed: Bool
        // One choice or none: the provider is the organization's.
        let isLocked: Bool
    }

    nonisolated static func choices(_ snapshot: ManagedPolicySnapshot) -> PersonalSyncChoices {
        personalSyncChoices(policy: snapshot.coreArgument, offered: offered)
    }

    nonisolated static func iCloud(_ snapshot: ManagedPolicySnapshot) -> ICloudStanding {
        let choices = choices(snapshot)
        return ICloudStanding(isAllowed: choices.providers.contains(.icloud), isLocked: choices.locked)
    }

    nonisolated static func disableReason(_ snapshot: ManagedPolicySnapshot) -> DisableReason? {
        iCloud(snapshot).isAllowed ? nil : .managedPolicy
    }

    // The provider the profile leaves this Mac on. A forced provider is taken as the person would pick it, so a forced
    // TablePro Sync still waits for the person's upload confirmation before anything goes up, and one taken away goes
    // off. Whether a server takes this Mac's data never changes what is stored: a server's answer moves no provider
    // (core ADR 0051, Policies).
    nonisolated static func settledProvider(
        _ provider: SyncProviderSetting,
        under snapshot: ManagedPolicySnapshot
    ) -> SyncProviderSetting {
        SyncProviderSetting(settledSyncProvider(
            policy: snapshot.coreArgument,
            offered: offered,
            current: SyncProviderTag(provider),
            tableproSyncAvailable: true
        ))
    }
}

extension SyncProviderTag {
    init(_ setting: SyncProviderSetting) {
        switch setting {
        case .off: self = .off
        case .iCloud: self = .icloud
        case .tableproSync: self = .tableproSync
        }
    }
}

extension SyncProviderSetting {
    init(_ tag: SyncProviderTag) {
        switch tag {
        case .off: self = .off
        case .icloud: self = .iCloud
        case .tableproSync: self = .tableproSync
        }
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
