//
//  LicensePresentation.swift
//  TablePro
//

import Foundation

internal enum LicenseNoticeAction: Equatable {
    case activate
    case renew
    case purchase
    case upgrade
    case retryValidation

    var title: String {
        switch self {
        case .activate: String(localized: "Activate License…")
        case .renew: String(localized: "Renew License")
        case .purchase: String(localized: "Buy a License")
        case .upgrade: String(localized: "Upgrade Plan")
        case .retryValidation: String(localized: "Try Again")
        }
    }
}

// The tone follows what the reader can do: `.critical` is a state with no way out, which is why a
// suspended license is red and an expired one, which offers Renew, is not.
internal enum LicenseNoticeTone: Equatable {
    case informational
    case warning
    case critical
}

internal struct LicenseNotice: Equatable {
    let title: String
    let message: String
    let action: LicenseNoticeAction?
    let tone: LicenseNoticeTone
}

internal struct LicenseActivationLink: Equatable {
    let title: String
    let destination: URL
}

internal struct LicenseActivationFailure: Equatable {
    let message: String
    let link: LicenseActivationLink?
}

internal struct LicenseFeatureGroup: Equatable, Identifiable {
    let tier: LicenseTier
    let includedTier: LicenseTier?
    let features: [ProFeature]
    let access: ProFeatureAccess

    var id: LicenseTier { tier }
}

// Every surface that shows license state renders this, so a state reads the same everywhere.
internal enum LicensePresentation {
    static func featureGroups(
        status: LicenseStatus,
        tier: LicenseTier,
        features: [ProFeature] = ProFeature.allCases
    ) -> [LicenseFeatureGroup] {
        var tiers: [LicenseTier] = []
        for feature in features where !tiers.contains(feature.requiredTier) {
            tiers.append(feature.requiredTier)
        }
        // Lowest tier first whatever the case order, so each plan names the one it builds on.
        tiers.sort { !$0.unlocks($1) }

        return tiers.enumerated().map { index, groupTier in
            LicenseFeatureGroup(
                tier: groupTier,
                includedTier: index > 0 ? tiers[index - 1] : nil,
                features: features.filter { $0.requiredTier == groupTier },
                access: LicenseManager.resolveAccess(status: status, tier: tier, requiredTier: groupTier)
            )
        }
    }

    static func showsLicensedLayout(status: LicenseStatus) -> Bool {
        status == .active
    }

    // An unverified license is one its owner holds, and typing a key needs the network the state
    // lacks. Its way out is the check.
    static func showsRenewalField(status: LicenseStatus) -> Bool {
        switch status {
        case .expired, .unlicensed, .suspended, .deactivated:
            return true
        case .active, .validationFailed:
            return false
        }
    }

    static func notice(
        status: LicenseStatus,
        daysUntilExpiry: Int?,
        isExpired: Bool,
        hasLicense: Bool
    ) -> LicenseNotice? {
        switch status {
        case .active:
            return expiryNotice(daysUntilExpiry: daysUntilExpiry, isExpired: isExpired)

        case .expired:
            return expiredNotice

        case .suspended:
            return suspendedNotice

        case .validationFailed:
            return unverifiedNotice

        case .deactivated:
            // Informational: the reader just chose this, and the field below it is the way back.
            return LicenseNotice(
                title: String(localized: "License Removed"),
                message: String(localized: "This Mac no longer holds a seat."),
                action: nil,
                tone: .informational
            )

        case .unlicensed:
            return hasLicense
                ? LicenseNotice(
                    title: String(localized: "License Not Recognized"),
                    message: String(localized: "The server no longer knows this license key."),
                    action: .purchase,
                    tone: .warning
                )
                : nil
        }
    }

    // A license state reads exactly as the License pane says it, so a paying customer is never
    // asked to buy; only a plan the license lacks names the plan.
    static func gate(for feature: ProFeature, access: ProFeatureAccess) -> LicenseNotice? {
        switch access {
        case .available:
            return nil
        case .unlicensed:
            return LicenseNotice(
                title: feature.planRequirement,
                message: feature.featureDescription,
                action: .activate,
                tone: .informational
            )
        case .requiresUpgrade:
            return LicenseNotice(
                title: feature.planRequirement,
                message: feature.featureDescription,
                action: .upgrade,
                tone: .informational
            )
        case .expired:
            return expiredNotice
        case .validationFailed:
            return unverifiedNotice
        case .suspended:
            return suspendedNotice
        }
    }

    static func welcomeLine(
        status: LicenseStatus,
        daysUntilExpiry: Int?,
        isExpired: Bool,
        hasLicense: Bool
    ) -> LicenseNotice? {
        if let notice = notice(
            status: status, daysUntilExpiry: daysUntilExpiry, isExpired: isExpired, hasLicense: hasLicense
        ) {
            return notice
        }
        guard status != .active else { return nil }
        return LicenseNotice(
            title: String(localized: "Activate License"),
            message: String(localized: "Enter your license key, or a team invite code to join a team."),
            action: .activate,
            tone: .informational
        )
    }

    static func checkFailureMessage(_ error: LicenseError) -> String {
        error.friendlyDescription
    }

    private static var expiredNotice: LicenseNotice {
        LicenseNotice(
            title: String(localized: "License Expired"),
            message: String(localized: "Renew it to use paid features again. Everything else keeps working."),
            action: .renew,
            tone: .warning
        )
    }

    private static var suspendedNotice: LicenseNotice {
        LicenseNotice(
            title: String(localized: "License Suspended"),
            message: String(localized: "Get in touch and we will sort it out."),
            action: nil,
            tone: .critical
        )
    }

    private static var unverifiedNotice: LicenseNotice {
        LicenseNotice(
            title: String(localized: "Could Not Check This License"),
            message: String(
                localized: "TablePro has not reached the license server in 30 days, so paid features are paused."
            ),
            action: .retryValidation,
            tone: .warning
        )
    }

    // The window is `LicenseManager.isExpiringSoon`, which refuses a license that already lapsed:
    // whole-day counting leaves one that ran out this morning at zero days.
    private static func expiryNotice(daysUntilExpiry: Int?, isExpired: Bool) -> LicenseNotice? {
        guard LicenseManager.isExpiringSoon(daysUntilExpiry: daysUntilExpiry, isExpired: isExpired),
              let days = daysUntilExpiry else { return nil }

        return LicenseNotice(
            title: String(localized: "License Expiring Soon"),
            message: expiryMessage(days: days),
            action: .renew,
            tone: .informational
        )
    }

    // Today and tomorrow are named rather than counted: "in 0 days" and "in 1 days".
    private static func expiryMessage(days: Int) -> String {
        switch days {
        case 0:
            return String(localized: "This license expires today.")
        case 1:
            return String(localized: "This license expires tomorrow.")
        default:
            return String(format: String(localized: "This license expires in %lld days."), days)
        }
    }

    // The Macs link goes with a license key only: an invite code fails the same way when the team
    // has no seat left, which only the team's owner can change.
    static func activationFailure(for error: Error, entry: String) -> LicenseActivationFailure {
        let licenseError = error as? LicenseError
        let message = licenseError?.friendlyDescription ?? error.localizedDescription

        guard case .activationLimitReached? = licenseError, LicenseManager.isLicenseKey(entry) else {
            return LicenseActivationFailure(message: message, link: nil)
        }

        return LicenseActivationFailure(
            message: message,
            link: LicenseActivationLink(
                title: String(localized: "Manage Macs"),
                destination: SupportLinks.accountMachines
            )
        )
    }

    static func deviceCount(used: Int, limit: Int) -> String {
        String(format: String(localized: "%1$lld of %2$lld devices"), used, limit)
    }

    // Members, not seats: one noun for both made releasing a Mac look like it freed a person.
    static func memberCount(used: Int, limit: Int) -> String {
        String(format: String(localized: "%1$lld of %2$lld members"), used, limit)
    }

    // A one-time license's "lifetime" cycle repeats "One-time", so it is dropped.
    static func planDescription(tier: String, billingCycle: String?, expiry: String?) -> String {
        var parts = [LicenseTier(rawValue: tier).displayName]

        if let expiry {
            if let cycle = billingCycle, !cycle.isEmpty {
                parts.append(cycle.capitalized)
            }
            parts.append(String(format: String(localized: "Expires %@"), expiry))
        } else {
            parts.append(String(localized: "One-time"))
        }

        return parts.joined(separator: ", ")
    }

    // A key is a bearer credential, so only its first group is on screen; Copy puts the real one on
    // the pasteboard.
    static func maskedKey(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 5, let first = parts.first else { return key }
        return String(first) + "…"
    }
}
