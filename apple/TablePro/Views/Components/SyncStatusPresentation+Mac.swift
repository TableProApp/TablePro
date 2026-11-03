//
//  SyncStatusPresentation+Mac.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

internal struct SyncNotice: Equatable {
    let symbolName: String
    let title: String
    let message: String
    let actions: [SyncStatusAction]
}

// The wording for this Mac. Titles, symbols and actions come from the shared presentation, and
// CloudKit's own descriptions never reach the screen.
internal extension SyncStatusPresentation {
    var message: String? {
        guard let error = status.error else { return nil }
        return Self.message(for: error)
    }

    // The caption under the Status row. A blocker is stated at length in the notice instead.
    var statusDetail: String? {
        guard let error = status.error, error.blocker == nil else { return nil }
        return Self.message(for: error)
    }

    // A blocker carries its own Try Again in the notice, where it is offered at all.
    var offersSyncNow: Bool {
        blocker == nil
    }

    var notice: SyncNotice? {
        guard let blocker else { return nil }
        return SyncNotice(
            symbolName: symbolName,
            title: title,
            message: Self.message(for: blocker),
            actions: actions
        )
    }

    // iCloud that is not ready yet clears on its own, so it stays in Settings.
    var showsOnWelcome: Bool {
        guard let blocker else { return false }
        return blocker != .accountNotReady
    }
}

private extension SyncStatusPresentation {
    static func message(for error: SyncError) -> String {
        switch error {
        case .blocked(let blocker):
            return message(for: blocker)
        case .offline:
            return String(localized: "Cannot reach iCloud. Changes sync when this Mac is back online.")
        case .busy:
            return String(localized: "iCloud asked TablePro to wait. It tries again on its own shortly.")
        case .recordsRejected(let count):
            // Two keys rather than inflection markup, which reads verbatim when a catalog lacks it.
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

    // The storage message names the path as text because the Manage Storage pane URL is not
    // documented, and on some macOS versions it lands on the wrong pane.
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
}
