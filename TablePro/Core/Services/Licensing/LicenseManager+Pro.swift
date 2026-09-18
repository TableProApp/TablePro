//
//  LicenseManager+Pro.swift
//  TablePro
//
//  Pro feature gating methods
//

import Foundation

/// Whether the person in front of the app has already paid for it.
///
/// Deliberately coarser than `ProFeatureAccess`: that answers "may this feature run right now",
/// which a reachable server can revoke, while this answers "did this person buy TablePro", which
/// a lost network connection cannot undo.
internal enum SupportAudience: Equatable {
    case supporter
    case prospect
}

extension LicenseManager {
    /// The tier of the current license, or `.starter` when unlicensed.
    var currentTier: LicenseTier {
        guard let license else { return .starter }
        return LicenseTier(rawValue: license.tier)
    }

    /// Check if a Pro feature is available (convenience for boolean checks)
    func isFeatureAvailable(_ feature: ProFeature) -> Bool {
        Self.resolveAccess(
            status: status,
            tier: currentTier,
            requiredTier: feature.requiredTier
        ) == .available
    }

    /// Check feature availability with detailed access result
    func checkFeature(_ feature: ProFeature) -> ProFeatureAccess {
        Self.resolveAccess(
            status: status,
            tier: currentTier,
            requiredTier: feature.requiredTier
        )
    }

    /// Pure resolution of feature access from license state. Kept static and side-effect free so
    /// gating logic can be unit tested without constructing a LicenseManager.
    nonisolated static func resolveAccess(
        status: LicenseStatus,
        tier: LicenseTier,
        requiredTier: LicenseTier
    ) -> ProFeatureAccess {
        guard status.isValid else {
            switch status {
            case .expired:
                return .expired
            case .validationFailed:
                return .validationFailed
            default:
                return .unlicensed
            }
        }

        guard tier.unlocks(requiredTier) else {
            return .requiresUpgrade(requiredTier)
        }

        return .available
    }

    /// Who the support screen is talking to.
    var supportAudience: SupportAudience {
        Self.resolveSupportAudience(hasLicense: license != nil, status: status)
    }

    /// Pure resolution, kept beside `resolveAccess` for the same reason: the whole grid can be
    /// tested without constructing a LicenseManager.
    ///
    /// `.active` covers the entire 30-day offline grace period, and `.validationFailed` is what
    /// follows it, so a paying customer who has simply been away from the network is never asked
    /// to buy a license they already own. `.expired` and `.suspended` are the server's own word
    /// that the license no longer stands, and `.deactivated` reaches here only from a server
    /// rejection, because a local deactivation clears the license outright.
    nonisolated static func resolveSupportAudience(
        hasLicense: Bool,
        status: LicenseStatus
    ) -> SupportAudience {
        guard hasLicense else { return .prospect }

        switch status {
        case .active, .validationFailed:
            return .supporter
        case .unlicensed, .expired, .suspended, .deactivated:
            return .prospect
        }
    }
}
