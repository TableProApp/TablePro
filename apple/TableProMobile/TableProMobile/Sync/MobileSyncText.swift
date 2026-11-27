import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The Sync page's words. The engine's own words never reach the screen; its code goes to the log.
nonisolated enum MobileSyncText {
    private static let logger = Logger(subsystem: "com.TablePro", category: "Sync")

    static func message(for error: any Error) -> String {
        if let error = error as? ProviderMoveError {
            switch error {
            case .notAllowed:
                return String(localized: "Your organization does not allow this on this device.")
            case .inProgress:
                return String(localized: "Another change to how this device syncs is still running.")
            case .serverRefusesPersonalSync:
                return String(localized: "Your server does not keep personal data, so this device cannot sync it there.")
            case .superseded:
                return String(localized: "How this device syncs changed while this ran, so it stopped.")
            case .signInChanged:
                return String(localized: "Your TablePro account changed, so nothing moved. Start again to see what this account gets.")
            case .engineUnavailable:
                return message(forCode: "")
            }
        }
        if case .Failed(let info)? = error as? CoreError {
            return message(forCode: info.code)
        }
        return message(forCode: "")
    }

    // Every `sync.*` code a move, a pass or a plan returns (core crates/sync/src/api), and the `account.*` ones the
    // account's part of a call can end in. A key's own failure (`keys.*`) reads as the keys not being held here.
    static func message(forCode code: String) -> String {
        if code.hasPrefix("keys.") {
            return keysUnreadable
        }
        if code.hasPrefix("sync.icloud.") {
            return iCloudMessage(code)
        }
        switch code {
        case "sync.locked", "sync.not_allowed", "sync.device_not_approved", "sync.device_removed":
            return keysUnreadable
        case "sync.device_store.locked":
            return String(localized: "Sync waits until you unlock this device. It starts again on its own.")
        case "sync.device_store.unavailable", "sync.device_store.failed":
            return String(localized: "This device has no place to keep its device keys, so it cannot use TablePro Sync.")
        case "sync.network", "sync.server", "sync.rate_limited", "sync.restore_check_unavailable", "sync.idempotency_in_progress",
             "sync.cursor_expired", "sync.epoch_changed", "sync.state.busy", "account.unreachable", "account.rate_limited":
            return String(localized: "TablePro Sync cannot be reached. Your data stays on this device; try again once you are online.")
        case "sync.feature_required", "sync.license_expired", "sync.seat_required", "account.entitlement":
            return String(localized: "Your account no longer includes TablePro Sync uploads. Your data stays on this device.")
        case "sync.signed_out", "sync.interactive_sign_in_required", "account.signed_out", "account.device_revoked":
            return String(localized: "Sign in to your TablePro account again, then try again.")
        case "sync.step_up_required", "account.step_up_required":
            return String(localized: "Confirm it's you in the sign-in page, then try again.")
        case "sync.changed", "sync.state.wrong_identity":
            return String(localized: "This changed while you were deciding. Look again, then choose.")
        case "sync.server_too_old":
            return String(localized: "Your TablePro server needs an update before this version of TablePro can sync with it.")
        case "sync.move_incomplete":
            return String(localized: "The move stopped before everything went up. Try again to go on from where it stopped.")
        case "sync.cancelled":
            return String(localized: "It was cancelled before it finished. Nothing changed.")
        default:
            return String(localized: "TablePro Sync could not finish. Your data stays on this device; try again later.")
        }
    }

    private static var keysUnreadable: String {
        String(localized: "This device cannot read your account's keys. Approve it from another device, or use your recovery key.")
    }

    private static func iCloudMessage(_ code: String) -> String {
        switch code {
        case "sync.icloud.no_account", "sync.icloud.account_changed", "sync.icloud.token_expired":
            return String(localized: "Sign in to iCloud in the Settings app to sync your connections.")
        case "sync.icloud.account_temporarily_unavailable":
            return String(localized: "iCloud is not ready on this device yet. Sync resumes on its own when it is.")
        case "sync.icloud.restricted":
            return String(localized: "Screen Time or device management does not allow iCloud on this device, so TablePro cannot sync.")
        case "sync.icloud.quota_exceeded":
            return String(localized: "There is not enough space in iCloud. Free up space or add storage, then try again.")
        case "sync.icloud.network", "sync.icloud.throttled", "sync.icloud.limit_exceeded":
            return String(localized: "Cannot reach iCloud. Changes sync when this device is back online.")
        case "sync.icloud.zone_deleted_by_user", "sync.icloud.zone_not_found":
            return String(localized: "TablePro's data is no longer in iCloud. It may have been deleted in iCloud settings.")
        default:
            return String(localized: "iCloud could not complete the sync. TablePro tries again on the next sync.")
        }
    }

    // The code goes to the log as public, the detail as private.
    static func log(_ what: String, _ error: any Error) {
        if case .Failed(let info)? = error as? CoreError {
            logger.error("\(what, privacy: .public): \(info.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
        } else {
            logger.error("\(what, privacy: .public): \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
    }

    // Two keys rather than inflection markup, which reads verbatim when a catalog lacks it.
    static func recordsLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 item goes up.")
            : String(format: String(localized: "%lld items go up."), Int64(clamping: count))
    }

    static func secretsLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 password is encrypted for TablePro Sync, and this device keeps its own copy.")
            : String(
                format: String(localized: "%lld passwords are encrypted for TablePro Sync, and this device keeps its own copy of each."),
                Int64(clamping: count)
            )
    }

    static func stayingBehindLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 item stays on this device: a Local only or sample connection, or a category you turned off.")
            : String(
                format: String(localized: "%lld items stay on this device: Local only and sample connections, and categories you turned off."),
                Int64(clamping: count)
            )
    }

    static func iCloudDeletionsLine(_ count: UInt64) -> String {
        count == 1
            ? String(localized: "1 item deleted on TablePro Sync since this device moved is deleted from iCloud too, unless another device changed it there.")
            : String(
                format: String(localized: "%lld items deleted on TablePro Sync since this device moved are deleted from iCloud too, unless another device changed them there."),
                Int64(clamping: count)
            )
    }

    // Recovery key setup and device approval come before the first upload (core ADR 0055, PersonalSyncProvider).
    static func keysMessage(_ state: KeyStateInfo) -> String {
        switch state {
        case .needsApproval:
            String(localized: "Approve this device from another device signed in to your account, or use your recovery key, then check again.")
        case .locked:
            String(localized: "This device can no longer read your account's keys. Approve it again from another device, then check again.")
        case .noDeviceStore:
            String(localized: "This device has no place to keep its device keys, so it cannot use TablePro Sync.")
        case .noKeys, .unknown, .approved:
            String(localized: "Set up a recovery key for your account before this device uploads, then check again.")
        }
    }
}

extension SyncProviderTag {
    nonisolated var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .icloud: "iCloud"
        case .tableproSync: "TablePro Sync"
        }
    }

    nonisolated var summary: String {
        switch self {
        case .off:
            String(localized: "Connections stay on this device.")
        case .icloud:
            String(localized: "Keep your connections and the items you choose the same on devices signed in to your Apple Account.")
        case .tableproSync:
            String(localized: "Sync through your TablePro account with every device signed in to it. Passwords, other secrets and query history are end-to-end encrypted.")
        }
    }
}

extension MobileSyncServerPolicy {
    nonisolated var message: String {
        switch self {
        case .personalSyncOff:
            String(localized: "Your server does not keep personal data, so this device keeps its own. Team Library goes on syncing.")
        case .passwordsOff:
            String(localized: "Your server does not sync passwords. Each one stays on this device.")
        case .historyOff:
            String(localized: "Your server does not sync query history. It stays on this device.")
        }
    }
}

extension MobileSyncServiceStatus {
    nonisolated var title: String {
        switch self {
        case .upToDate: String(localized: "Up to Date")
        case .syncing: String(localized: "Syncing…")
        case .waiting: String(localized: "Waiting to Retry")
        case .downloadOnly: String(localized: "Downloading Only")
        case .needsApproval: String(localized: "Needs Approval")
        case .off: String(localized: "Sync Off")
        case .unavailable: String(localized: "Sync Is Unavailable")
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .upToDate: "checkmark.circle"
        case .syncing: "arrow.triangle.2.circlepath"
        case .waiting: "clock"
        case .downloadOnly: "arrow.down.circle"
        case .needsApproval: "person.badge.key"
        case .off: "slash.circle"
        case .unavailable: "exclamationmark.circle"
        }
    }

    nonisolated var isWarning: Bool {
        switch self {
        case .waiting, .downloadOnly, .needsApproval, .unavailable: true
        case .upToDate, .syncing, .off: false
        }
    }
}
