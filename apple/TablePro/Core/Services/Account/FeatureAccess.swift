//
//  FeatureAccess.swift
//  TablePro
//

import Combine
import Foundation
import TableProCloudAPI

internal enum EntitlementRefreshState: Equatable, Sendable {
    case idle
    case succeeded(Date)
    case failed(AccountError)
    case deviceLimitReached([Components.Schemas.LicensedDevice])
}

internal struct AccountState: Equatable, Sendable {
    var isSignedIn = false
    var entitlement: Entitlement?
    var legacy: LegacyEntitlement?
    var refresh: EntitlementRefreshState = .idle
}

// Whether the person in front of the app has paid, which losing the network cannot undo.
internal enum SupportAudience: Equatable {
    case supporter
    case prospect
}

// Maps the entitlement's feature codes to what each gate shows.
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
        Self.resolve(feature, state: state, now: now())
    }

    var supportAudience: SupportAudience {
        Self.resolveSupportAudience(state: state)
    }

    var currentEntitlement: Entitlement? {
        state.entitlement.flatMap { $0.isValid(at: now()) ? $0 : nil }
    }

    nonisolated static func resolve(_ feature: ProFeature, state: AccountState, now: Date) -> ProFeatureAccess {
        let code = feature.rawValue
        let entitlement = state.entitlement.flatMap { $0.isValid(at: now) ? $0 : nil }
        let legacy = state.legacy.flatMap { $0.isValid(at: now) ? $0 : nil }

        if entitlement?.features.contains(code) == true || legacy?.features.contains(code) == true {
            return .available
        }
        if entitlement != nil || legacy != nil {
            return .notIncluded
        }
        if state.entitlement?.features.contains(code) == true || state.legacy?.features.contains(code) == true {
            return .expired
        }
        if !state.isSignedIn {
            return .signedOut
        }
        if case .deviceLimitReached = state.refresh {
            return .notIncluded
        }
        return .refreshFailed
    }

    // A lapsed entitlement still names its licenses: someone offline past expiry has still paid.
    nonisolated static func resolveSupportAudience(state: AccountState) -> SupportAudience {
        if let entitlement = state.entitlement, !entitlement.licenses.isEmpty {
            return .supporter
        }
        return state.legacy == nil ? .prospect : .supporter
    }
}
