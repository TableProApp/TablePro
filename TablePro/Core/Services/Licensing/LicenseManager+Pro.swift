//
//  LicenseManager+Pro.swift
//  TablePro
//
//  Pro feature gating methods
//

import Foundation

extension LicenseManager {
    /// Check if a Pro feature is available (convenience for boolean checks)
    func isFeatureAvailable(_ feature: ProFeature) -> Bool {
        status.isValid
    }

    /// Check feature availability with detailed access result
    func checkFeature(_ feature: ProFeature) -> ProFeatureAccess {
        if status.isValid {
            return .available
        }

        switch status {
        case .expired:
            return .expired
        case .validationFailed:
            return .validationFailed
        default:
            return .unlicensed
        }
    }
}
