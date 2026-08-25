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
    case activate
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

    /// The notice for a state that needs saying something, or nil when everything is in order.
    static func notice(
        status: LicenseStatus,
        daysUntilExpiry: Int?,
        hasLicense: Bool
    ) -> LicenseNotice? {
        switch status {
        case .active:
            return expiryNotice(daysUntilExpiry: daysUntilExpiry)

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
                message: String(localized: "This Mac no longer holds a seat. Activate a license to use Pro features."),
                action: .activate,
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
    /// count down to. This is the single owner of that window.
    private static func expiryNotice(daysUntilExpiry: Int?) -> LicenseNotice? {
        guard let days = daysUntilExpiry, days >= 0, days <= 7 else { return nil }

        return LicenseNotice(
            title: String(localized: "License Expiring Soon"),
            message: String(format: expiryMessageFormat, days),
            action: .renew,
            tone: .informational
        )
    }

    /// Held apart so the plural variation has a stable key to hang off.
    private static var expiryMessageFormat: String {
        String(localized: "This license expires in %lld days.")
    }

    /// The seat count, as a phrase rather than two numbers glued together, so a translation can put
    /// them wherever its grammar needs and vary the noun by count.
    static func deviceCount(used: Int, limit: Int) -> String {
        String(format: String(localized: "%1$lld of %2$lld devices"), used, limit)
    }

    static func seatCount(used: Int, limit: Int) -> String {
        String(format: String(localized: "%1$lld of %2$lld seats"), used, limit)
    }

    /// The masked form of a license key: the first group, then the rest concealed.
    ///
    /// A key is a bearer credential, so it is never on screen in full. Copy puts the real one on the
    /// pasteboard instead, which is the task anybody actually has.
    static func maskedKey(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 5 else { return key }
        return ([String(parts[0])] + Array(repeating: "•••••", count: 4)).joined(separator: "-")
    }
}
