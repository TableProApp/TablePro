//
//  FeatureAccess.swift
//  TablePro
//

import Combine
import Foundation

internal enum EntitlementRefreshState: Equatable, Sendable {
    case idle
    case succeeded(Date)
    case failed(AccountError)
    case deviceLimitReached([AccountDevice])
}

internal struct AccountState: Equatable, Sendable {
    var isSignedIn = false
    var entitlement: Entitlement?
    var refresh: EntitlementRefreshState = .idle
    var server: AccountServer = .production
    var serverLicense: AccountServerLicense?
    // The core's gate for each feature, as it answered at the last change.
    var features: [ProFeature: ProFeatureAccess] = [:]
    // When this Mac last heard from the server that the entitlement holds.
    var verifiedAt: Date?
    // False until the core has read the last run's sign-in: a change before then is no sign-in or server change.
    var isRestored = false
}

// Whether the person in front of the app has paid, which losing the network cannot undo.
internal enum SupportAudience: Equatable {
    case supporter
    case prospect
}

// What each gate shows, from the core's answer for the feature's code.
@MainActor
internal final class FeatureAccess: ObservableObject {
    static let shared = FeatureAccess()

    @Published private(set) var state: AccountState
    private let now: () -> Date

    init(state: AccountState = AccountState(), now: @escaping () -> Date = { Date() }) {
        self.state = state
        self.now = now
    }

    func update(_ newState: AccountState) {
        guard newState != state else { return }
        state = newState
        AppEvents.shared.licenseStatusDidChange.send(())
    }

    func isAvailable(_ feature: ProFeature) -> Bool {
        check(feature) == .available
    }

    func check(_ feature: ProFeature) -> ProFeatureAccess {
        Self.resolve(feature, state: state)
    }

    var supportAudience: SupportAudience {
        Self.resolveSupportAudience(state: state)
    }

    // A licensed account whose 3 slots other devices hold: the gates point at Settings, not at a purchase.
    var isPastDeviceLimit: Bool {
        if case .deviceLimitReached = state.refresh {
            return true
        }
        return false
    }

    var currentEntitlement: Entitlement? {
        state.entitlement.flatMap { $0.isValid(at: now()) ? $0 : nil }
    }

    nonisolated static func resolve(_ feature: ProFeature, state: AccountState) -> ProFeatureAccess {
        state.features[feature] ?? (state.isSignedIn ? .refreshFailed : .signedOut)
    }

    // A lapsed entitlement still names its licenses: someone offline past expiry has still paid. A company server's
    // people are covered by its organization's license.
    nonisolated static func resolveSupportAudience(state: AccountState) -> SupportAudience {
        if !state.server.isProduction {
            return .supporter
        }
        if let entitlement = state.entitlement, !entitlement.licenses.isEmpty {
            return .supporter
        }
        return .prospect
    }
}
