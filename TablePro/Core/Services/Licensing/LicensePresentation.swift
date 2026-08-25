//
//  LicensePresentation.swift
//  TablePro
//
//  What the license pane says for a given license state
//

import Foundation

/// The action a degraded license offers, if any.
internal enum LicenseNoticeAction: Equatable {
    case renew
    case retryValidation
    case purchase
}

/// How prominent a notice is, which decides its symbol and tint without the view branching on
/// status a second time.
internal enum LicenseNoticeTone: Equatable {
    case informational
    case warning
    case critical
}

/// A notice shown inside the pane, never as an alert or a floating banner.
///
/// The tone follows what the reader can do about the state, not how bad the state sounds.
/// `.critical` is reserved for a state offering no way out, which is why a suspended license is red
/// and an expired one, which offers Renew, is not.
///
/// Title, body and one action, which is the shape Apple's own settings panes use for a degraded
/// state (`Action Required` plus `Try Again`), and what the HIG asks for when it says to put status
/// feedback next to what it describes.
internal struct LicenseNotice: Equatable {
    let title: String
    let message: String
    let action: LicenseNoticeAction?
    let tone: LicenseNoticeTone
}

/// Turns license state into what the pane shows. Pure and free of any view type, so the whole grid
/// of states can be tested without building a view, the same way `LicenseManager.resolveStatus` is.
internal enum LicensePresentation {
    /// Whether this license currently entitles anything.
    ///
    /// The pane uses it to decide whether a renewal field belongs beside the license, not whether
    /// the license is shown at all: branching the whole layout on it is what left an expired
    /// license with no field to type a renewal key into.
    static func showsLicensedLayout(status: LicenseStatus) -> Bool {
        status == .active
    }

    /// Whether typing a new key is the way out of this state.
    ///
    /// Not simply "is not entitled": a license the server has not confirmed for 30 days is one the
    /// owner already holds, and asking them for a key needs the network the state is defined by
    /// lacking. Their way out is the check, which the notice offers.
    static func showsRenewalField(status: LicenseStatus) -> Bool {
        switch status {
        case .expired, .unlicensed, .suspended, .deactivated:
            return true
        case .active, .validationFailed:
            return false
        }
    }

    /// The notice for a state that needs saying something, or nil when everything is in order.
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
            return LicenseNotice(
                title: String(localized: "License Expired"),
                message: String(localized: "Renew it to use Pro features again. Everything else keeps working."),
                action: .renew,
                tone: .warning
            )

        case .suspended:
            return LicenseNotice(
                title: String(localized: "License Suspended"),
                message: String(localized: "Get in touch and we will sort it out."),
                action: nil,
                tone: .critical
            )

        case .validationFailed:
            return LicenseNotice(
                title: String(localized: "Could Not Check This License"),
                message: String(
                    localized: "TablePro has not reached the license server in 30 days, so Pro features are paused."
                ),
                action: .retryValidation,
                tone: .warning
            )

        case .deactivated:
            return LicenseNotice(
                title: String(localized: "License Removed"),
                message: String(localized: "This Mac no longer holds a seat."),
                action: nil,
                /// Informational, not a warning: this reports something the reader just chose to
                /// do, and the field below it is already the way back.
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

    /// Warns only inside the last week, and never for a lifetime license, which has no expiry to
    /// count down to. The window itself is `LicenseManager.isExpiringSoon`, which also refuses a
    /// license that has already lapsed: whole-day counting leaves one that ran out this morning
    /// still reporting zero, which read as "expires in 0 days" beside a state saying Expired.
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

    /// Today and tomorrow are named rather than counted, because a countdown reads "in 0 days" and
    /// "in 1 days" on exactly the two days the notice exists to act on.
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

    /// The seat count, as a phrase rather than two numbers glued together, so a translation can put
    /// them wherever its grammar needs and vary the noun by count.
    static func deviceCount(used: Int, limit: Int) -> String {
        String(format: String(localized: "%1$lld of %2$lld devices"), used, limit)
    }

    /// The Team section lists members, so it counts members. "Seats" is what the Devices list
    /// spends, and using one noun for both made releasing a Mac look like it freed a person.
    static func memberCount(used: Int, limit: Int) -> String {
        String(format: String(localized: "%1$lld of %2$lld members"), used, limit)
    }

    /// What a licence is, in one line under the licensee's email.
    ///
    /// A lifetime licence states that once. Its billing cycle is already the word "lifetime", so
    /// taking the cycle and the absent expiry both spelled the plan "Team · Lifetime · Lifetime".
    static func planDescription(tier: String, billingCycle: String?, expiry: String?) -> String {
        var parts = [LicenseTier(rawValue: tier).displayName]

        if let expiry {
            if let cycle = billingCycle, !cycle.isEmpty {
                parts.append(cycle.capitalized)
            }
            parts.append(String(format: String(localized: "Expires %@"), expiry))
        } else {
            parts.append(String(localized: "Lifetime"))
        }

        return parts.joined(separator: " · ")
    }

    /// The first group of a license key, with the rest withheld.
    ///
    /// A key is a bearer credential, so it is never on screen in full, and Copy puts the real one on
    /// the pasteboard instead. Only the first group is shown: a full-length run of dots is identical
    /// for every licence, so it took the width of a real key to say nothing and then had its own end
    /// truncated away. One group is enough to tell which licence this is.
    static func maskedKey(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 5, let first = parts.first else { return key }
        return String(first) + "…"
    }
}
