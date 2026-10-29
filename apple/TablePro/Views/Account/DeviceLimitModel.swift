//
//  DeviceLimitModel.swift
//  TablePro
//

import Combine
import Foundation
import TableProCloudAPI

// The devices holding the license's 3 slots when the entitlement answered device_limit_reached (clients.md,
// Settings > Account). The app stays on the free tier until one is removed here or in the portal.
@MainActor
internal final class DeviceLimitModel: ObservableObject {
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        let system: String
        let lastSeenAt: Date
        // Set while the device's offline file is valid: the server refuses to remove it until then.
        let offlineUntil: Date?
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var removing: String?
    @Published private(set) var failure: String?
    @Published private(set) var isResolved = false

    let services: AccountServices
    private let now: () -> Date
    private var stateObserver: AnyCancellable?

    init(services: AccountServices, now: @escaping () -> Date = { Date() }) {
        self.services = services
        self.now = now
        rows = Self.rows(state: services.access.state, now: now())
        isResolved = !Self.isDeviceLimit(services.access.state.refresh)
        // Once resolved the rows stay as they were, so the sheet does not empty out while it closes.
        stateObserver = services.access.$state
            .dropFirst()
            .sink { [weak self] state in
                guard let self else { return }
                isResolved = !Self.isDeviceLimit(state.refresh)
                if !isResolved {
                    rows = Self.rows(state: state, now: self.now())
                }
            }
    }

    func remove(_ row: Row) async {
        failure = nil
        removing = row.id
        defer { removing = nil }
        do throws(AccountError) {
            try await services.removeDevice(row.id)
        } catch {
            failure = error.deviceRemovalDescription
            return
        }
        if case .failed(let error) = services.access.state.refresh {
            failure = error.friendlyDescription
        }
    }

    private static func isDeviceLimit(_ refresh: EntitlementRefreshState) -> Bool {
        if case .deviceLimitReached = refresh {
            return true
        }
        return false
    }

    private static func rows(state: AccountState, now: Date) -> [Row] {
        guard case .deviceLimitReached(let holders) = state.refresh else { return [] }
        return holders.map { holder in
            let device = AccountDevice(holder)
            return Row(
                id: device.id,
                name: device.name,
                system: AccountCodes.systemName(platform: device.platform, osVersion: device.osVersion),
                lastSeenAt: device.lastSeenAt,
                offlineUntil: device.offlineFileValid(at: now) ? device.offlineUntil : nil
            )
        }
    }
}
