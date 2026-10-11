//
//  SyncStatusPresentation.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

/// What a sync notice offers to do about the state it reports.
internal enum SyncNoticeAction: Hashable {
    case manageStorage
    case openAccountSettings
    case checkForUpdates
    case uploadAgain
    case turnOffSync
    case renewLicense
    case checkLicenseAgain
}

/// A state sync cannot leave on its own, stated inline at the top of the Sync pane rather than as an
/// alert, beside the switch it explains.
internal struct SyncNotice: Equatable {
    let symbolName: String
    let title: String
    let message: String
    let actions: [SyncNoticeAction]
}

/// How macOS words a sync status, for the welcome indicator and the Sync pane alike.
///
/// The one place that does, so the two cannot describe the same state in different words. It reads
/// only `SyncStatus`, which carries no text, so CloudKit's own descriptions and record ids have no
/// way onto the screen. Every switch is exhaustive: a new status has to be worded here before the
/// app builds.
internal struct SyncStatusPresentation {
    let status: SyncStatus
    let lastSyncDate: Date?

    init(status: SyncStatus, lastSyncDate: Date? = nil) {
        self.status = status
        self.lastSyncDate = lastSyncDate
    }
}

internal extension SyncStatusPresentation {
    /// Sync the person turned off has nothing to report, and an indicator would only restate the
    /// switch.
    var showsIndicator: Bool {
        status != .disabled(.userDisabled)
    }

    var indicatorLabel: String {
        switch status {
        case .idle:
            return String(localized: "Synced")
        case .syncing:
            return String(localized: "Syncing…")
        case .error(let error):
            return Self.indicatorLabel(for: error)
        case .disabled(.licenseRequired), .disabled(.licenseExpired):
            return String(localized: "Sync Off")
        case .disabled(.licenseUnverified):
            return String(localized: "Sync Paused")
        case .disabled(.userDisabled):
            return ""
        }
    }

    /// Every symbol here ships with macOS 13. The circlepath and dashed iCloud variants do not.
    var symbolName: String {
        switch status {
        case .idle:
            return "checkmark.icloud"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .error(.blocked(let blocker)):
            return Self.symbolName(for: blocker)
        case .error(.offline):
            return "icloud.slash"
        case .error(.busy), .error(.recordsRejected), .error(.pullNotSaved), .error(.unexpected):
            return "exclamationmark.icloud"
        case .disabled(.licenseRequired), .disabled(.licenseExpired):
            return "xmark.icloud"
        case .disabled(.licenseUnverified):
            return "exclamationmark.icloud"
        case .disabled(.userDisabled):
            return "icloud.slash"
        }
    }

    /// Every failure is one, whatever the cause, because changes are not reaching iCloud. A license
    /// state is not: sync is off rather than failing, and the Sync pane states it as a notice.
    var isWarning: Bool {
        switch status {
        case .error:
            return true
        case .idle, .syncing, .disabled:
            return false
        }
    }

    var helpText: String {
        helpText(relativeTo: Date())
    }

    func helpText(relativeTo now: Date) -> String {
        switch status {
        case .idle:
            guard let lastSyncDate else { return String(localized: "iCloud Sync is active") }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: lastSyncDate, relativeTo: now)
            return String(format: String(localized: "Last synced %@"), relative)
        case .syncing:
            return String(localized: "Syncing with iCloud…")
        case .error(let error):
            return Self.message(for: error)
        case .disabled(.licenseRequired):
            return ProFeature.iCloudSync.planRequirement
        case .disabled(.licenseExpired):
            return String(localized: "License expired, sync paused")
        case .disabled(.licenseUnverified):
            return String(localized: "License not verified in 30 days, sync paused. Click to check again.")
        case .disabled(.userDisabled):
            return ""
        }
    }

    /// The value of the Status row in the Sync pane.
    var statusTitle: String {
        switch status {
        case .idle:
            return String(localized: "Up to Date")
        case .syncing:
            return String(localized: "Syncing…")
        case .error(.blocked(let blocker)):
            return Self.title(for: blocker)
        case .error(.offline):
            return String(localized: "Offline")
        case .error(.busy):
            return String(localized: "Waiting to Retry")
        case .error(.recordsRejected):
            return String(localized: "Some Changes Not Uploaded")
        case .error(.pullNotSaved):
            return String(localized: "Changes Not Saved")
        case .error(.unexpected):
            return String(localized: "Sync Failed")
        case .disabled(.licenseRequired), .disabled(.licenseExpired), .disabled(.userDisabled):
            return String(localized: "Sync Off")
        case .disabled(.licenseUnverified):
            return String(localized: "Sync Paused")
        }
    }

    /// What happened, that nothing is lost where that holds, and what makes sync resume. Nil when
    /// there is nothing to explain.
    var message: String? {
        switch status {
        case .idle, .syncing:
            return nil
        case .error(let error):
            return Self.message(for: error)
        case .disabled(.licenseExpired):
            return Self.licenseExpiredMessage
        case .disabled(.licenseUnverified):
            return Self.licenseUnverifiedMessage
        case .disabled(.licenseRequired), .disabled(.userDisabled):
            return nil
        }
    }

    /// The caption under the Status row. Nil for a blocked state, whose notice at the top of the
    /// pane already says it at length.
    var statusDetail: String? {
        guard case .error(let error) = status, error.blocker == nil else { return nil }
        return Self.message(for: error)
    }

    /// Hidden once TablePro's data is gone from iCloud: a sync would upload it again, and that is
    /// the person's call, made through the notice.
    var offersSyncNow: Bool {
        status.error != .blocked(.dataDeletedFromICloud)
    }

    /// A required license is not a notice: the Pro badge beside the switch already says it.
    var notice: SyncNotice? {
        switch status {
        case .error(.blocked(let blocker)):
            return SyncNotice(
                symbolName: symbolName,
                title: Self.title(for: blocker),
                message: Self.message(for: blocker),
                actions: Self.actions(for: blocker)
            )
        case .disabled(.licenseExpired):
            return SyncNotice(
                symbolName: symbolName,
                title: String(localized: "Sync Paused"),
                message: Self.licenseExpiredMessage,
                actions: [.renewLicense]
            )
        case .disabled(.licenseUnverified):
            /// Not a license to buy again. The way out is the network, so the action is the check,
            /// never a purchase.
            return SyncNotice(
                symbolName: symbolName,
                title: String(localized: "Sync Paused"),
                message: Self.licenseUnverifiedMessage,
                actions: [.checkLicenseAgain]
            )
        case .idle, .syncing,
             .error(.offline), .error(.busy), .error(.recordsRejected), .error(.pullNotSaved), .error(.unexpected),
             .disabled(.licenseRequired), .disabled(.userDisabled):
            return nil
        }
    }
}

internal extension SyncNoticeAction {
    var title: String {
        switch self {
        case .manageStorage:
            return String(localized: "Manage Storage…")
        case .openAccountSettings:
            return String(localized: "Open System Settings…")
        case .checkForUpdates:
            return String(localized: "Check for Updates…")
        case .uploadAgain:
            return String(localized: "Upload Again")
        case .turnOffSync:
            return String(localized: "Turn Off Sync")
        case .renewLicense:
            return String(localized: "Renew License")
        case .checkLicenseAgain:
            return String(localized: "Check Again")
        }
    }
}

private extension SyncStatusPresentation {
    static var licenseExpiredMessage: String {
        String(localized: "The license that covers iCloud Sync has expired. Renew it to start syncing again.")
    }

    static var licenseUnverifiedMessage: String {
        String(localized: "TablePro has not confirmed this license with the server in 30 days.")
    }

    static func indicatorLabel(for error: SyncError) -> String {
        switch error {
        case .blocked(.storageFull):
            return String(localized: "iCloud Full")
        case .blocked(.signedOut):
            return String(localized: "No iCloud")
        case .blocked(.accountNotReady), .blocked(.dataDeletedFromICloud):
            return String(localized: "Sync Paused")
        case .blocked(.accountRestricted), .blocked(.unavailable):
            return String(localized: "Sync Off")
        case .blocked(.appUpdateRequired):
            return String(localized: "Update Needed")
        case .offline:
            return String(localized: "Offline")
        case .busy:
            return String(localized: "Sync Delayed")
        case .recordsRejected, .pullNotSaved, .unexpected:
            return String(localized: "Sync Error")
        }
    }

    static func symbolName(for blocker: SyncBlocker) -> String {
        switch blocker {
        case .signedOut:
            return "icloud.slash"
        case .accountRestricted, .unavailable:
            return "xmark.icloud"
        case .storageFull, .accountNotReady, .dataDeletedFromICloud, .appUpdateRequired:
            return "exclamationmark.icloud"
        }
    }

    static func title(for blocker: SyncBlocker) -> String {
        switch blocker {
        case .storageFull:
            return String(localized: "iCloud Storage Is Full")
        case .signedOut:
            return String(localized: "Not Signed In to iCloud")
        case .accountNotReady:
            return String(localized: "iCloud Is Not Ready")
        case .accountRestricted:
            return String(localized: "iCloud Is Restricted")
        case .dataDeletedFromICloud:
            return String(localized: "TablePro Data Was Removed from iCloud")
        case .appUpdateRequired:
            return String(localized: "Update Required")
        case .unavailable:
            return String(localized: "Sync Is Unavailable")
        }
    }

    static func message(for error: SyncError) -> String {
        switch error {
        case .blocked(let blocker):
            return message(for: blocker)
        case .offline:
            return String(localized: "Cannot reach iCloud. Changes sync when this Mac is back online.")
        case .busy:
            return String(localized: "iCloud asked TablePro to wait. It tries again on its own shortly.")
        case .recordsRejected(let count):
            /// Two keys rather than inflection markup, which reads verbatim when a catalog lacks it.
            let template = count == 1
                ? String(
                    localized: """
                        %lld change could not be uploaded to iCloud. It stays on this Mac and goes again \
                        on the next sync. Everything else is up to date.
                        """
                )
                : String(
                    localized: """
                        %lld changes could not be uploaded to iCloud. They stay on this Mac and go again \
                        on the next sync. Everything else is up to date.
                        """
                )
            return String(format: template, count)
        case .pullNotSaved:
            return String(
                localized: "Changes from iCloud could not be saved on this Mac. They download again on the next sync."
            )
        case .unexpected:
            return String(localized: "iCloud could not complete the sync. TablePro tries again on the next sync.")
        }
    }

    /// The storage message names the path as text because the Manage Storage pane URL is not
    /// documented, and on some macOS versions it lands on the wrong pane.
    static func message(for blocker: SyncBlocker) -> String {
        switch blocker {
        case .storageFull:
            return String(
                localized: """
                    TablePro cannot upload changes until there is space in iCloud. Changes from this Mac \
                    are kept here and upload once you free up space or add storage. To manage storage, \
                    open System Settings, click your name, then click iCloud.
                    """
            )
        case .signedOut:
            return String(
                localized: "Sign in with your Apple Account in System Settings to sync connections and settings between your Macs."
            )
        case .accountNotReady:
            return String(localized: "iCloud is not ready on this Mac yet. Sync resumes on its own when it is.")
        case .accountRestricted:
            return String(
                localized: "Screen Time or device management does not allow iCloud on this Mac, so TablePro cannot sync."
            )
        case .dataDeletedFromICloud:
            return String(
                localized: """
                    TablePro's data is no longer in iCloud. It may have been deleted in iCloud settings. \
                    Upload what this Mac has again, or turn off sync to keep it on this Mac only.
                    """
            )
        case .appUpdateRequired:
            return String(localized: "This version of TablePro can no longer sync with iCloud. Update TablePro to resume.")
        case .unavailable:
            return String(localized: "iCloud sync is not available in this build of TablePro.")
        }
    }

    static func actions(for blocker: SyncBlocker) -> [SyncNoticeAction] {
        switch blocker {
        case .storageFull:
            return [.manageStorage]
        case .signedOut:
            return [.openAccountSettings]
        case .dataDeletedFromICloud:
            return [.uploadAgain, .turnOffSync]
        case .appUpdateRequired:
            return [.checkForUpdates]
        case .accountNotReady, .accountRestricted, .unavailable:
            return []
        }
    }
}
