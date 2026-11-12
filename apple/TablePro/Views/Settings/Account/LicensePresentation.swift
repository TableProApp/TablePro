//
//  LicensePresentation.swift
//  TablePro
//

import Foundation

internal enum LicenseNoticeAction: Equatable {
    case signIn
    case purchase
    case upgrade
    case renew
    case retryValidation
    case openAccountSettings

    var title: String {
        switch self {
        case .signIn: String(localized: "Sign In")
        case .purchase: String(localized: "Purchase License")
        case .upgrade: String(localized: "Upgrade Plan")
        case .renew: String(localized: "Renew License")
        case .retryValidation: String(localized: "Try Again")
        case .openAccountSettings: String(localized: "Open Account Settings…")
        }
    }

    var opensPricing: Bool {
        switch self {
        case .purchase, .upgrade, .renew: true
        case .signIn, .retryValidation, .openAccountSettings: false
        }
    }
}

internal struct LicenseNotice: Equatable {
    let title: String
    let message: String
    let action: LicenseNoticeAction?
    // Only signed out has two ways out: signing in to a plan this account holds, or buying one.
    var alternative: LicenseNoticeAction?
}

// Every surface that shows account state renders this, so a state reads the same everywhere.
internal enum LicensePresentation {
    // A plan this Mac could not check reads as Settings > Account says it, so a paying customer is never asked to
    // buy; only an account without the feature names a paid plan.
    static func gate(for feature: ProFeature, state: AccountState, now: Date) -> LicenseNotice? {
        switch FeatureAccess.resolve(feature, state: state, now: now) {
        case .available:
            return nil
        case .signedOut:
            return LicenseNotice(
                title: feature.paidPlanRequirement,
                message: feature.featureDescription,
                action: .signIn,
                alternative: .purchase
            )
        case .notIncluded:
            if case .deviceLimitReached = state.refresh {
                return LicenseNotice(
                    title: String(localized: "Your plan is in use on 3 other devices"),
                    message: String(localized: "Remove one in Settings to use your plan on this Mac."),
                    action: .openAccountSettings
                )
            }
            return LicenseNotice(title: feature.paidPlanRequirement, message: feature.featureDescription, action: .upgrade)
        case .expired:
            if let entitlement = state.entitlement, entitlement.features.contains(feature.rawValue) {
                return notice(.expired(at: entitlement.expiresAt, isOfflineFile: entitlement.isOffline))
            }
            // A key from an older build past its own end date; one only past its 30 days waits for the exchange.
            if let expiresAt = state.legacy?.expiresAt, expiresAt <= now {
                return LicenseNotice(
                    title: String(localized: "Your license has expired"),
                    message: feature.featureDescription,
                    action: .renew
                )
            }
            return notice(.verificationFailed(message: nil))
        case .refreshFailed:
            return notice(.verificationFailed(message: nil))
        }
    }

    // The pane's first notice, then Sign In for a Mac with no account and no key from an older build. A canceling
    // plan stays in the pane: the person chose it, and the pane shows the date it ends.
    static func welcomeLine(state: AccountState, configuration: AccountConfiguration, now: Date) -> LicenseNotice? {
        let notices = AccountSettingsContent.notices(state: state, configuration: configuration, now: now)
        if let first = notices.first(where: { !$0.isCanceling }) {
            return notice(first)
        }
        guard !state.isSignedIn, state.legacy == nil else { return nil }
        return LicenseNotice(
            title: String(localized: "Sign In"),
            message: String(
                localized: "Your account unlocks the features your plan includes, on up to 3 devices. Everything else works without an account."
            ),
            action: .signIn
        )
    }

    static func notice(_ notice: AccountSettingsContent.Notice) -> LicenseNotice {
        LicenseNotice(title: notice.title, message: notice.message, action: action(for: notice))
    }

    // Where the pane offers a way out in place, a surface without the pane's room opens it.
    static func action(for notice: AccountSettingsContent.Notice) -> LicenseNoticeAction? {
        switch notice {
        case .expiringSoon(_, false), .expired(_, false), .verificationFailed:
            return .retryValidation
        case .deviceLimit, .paymentProblem, .expiringSoon(_, true), .expired(_, true):
            return .openAccountSettings
        case .canceling:
            return nil
        }
    }

    static func checkFailureMessage(_ refresh: EntitlementRefreshState) -> String? {
        guard case .failed(let error) = refresh else { return nil }
        return error.friendlyDescription
    }
}

private extension AccountSettingsContent.Notice {
    var isCanceling: Bool {
        if case .canceling = self { return true }
        return false
    }
}
