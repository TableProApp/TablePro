//
//  LicenseManager+Pro.swift
//  TablePro
//
//  Pro feature gating methods
//

import Foundation

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
}
