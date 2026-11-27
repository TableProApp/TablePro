import Foundation
import os
import TableProFFI
import TableProLogRedaction

// The words the encryption screens use for what the core answers by code (core AGENTS.md, Errors carry a code), as
// the Mac words them, for this device.
nonisolated enum AccountKeysText {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AccountKeys")

    static var generic: String {
        String(localized: "Something went wrong. Try again.")
    }

    // The code goes to the log as public and the detail as private, so a report names the failure and never its data.
    static func log(_ error: any Error, while action: String) {
        if case .Failed(let info)? = error as? CoreError {
            logger.error("\(action, privacy: .public) failed: \(info.code, privacy: .public) \(info.message, privacy: .private)")
        } else {
            logger.error("\(action, privacy: .public) failed: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
    }

    static func message(for error: any Error) -> String {
        if let error = error as? AccountError {
            return error.mobileDescription ?? generic
        }
        if error is KeyServiceUnavailable {
            return String(localized: "Sign in to your TablePro account to use end-to-end encryption.")
        }
        guard case .Failed(let info)? = error as? CoreError else {
            return generic
        }
        if case .rejected(let code)? = info.sync, let message = rejection(code) {
            return message
        }
        if case .locked(let cause)? = info.sync {
            return lockMessage(cause)
        }
        return message(code: info.code)
    }

    // Every `sync.*` and `keys.*` code a key call can end with; `account.*` reaches here only as an AccountError.
    static func message(code: String) -> String {
        switch code {
        case "sync.typed_back_wrong":
            return String(localized: "Those groups don't match your recovery key. Check them and try again.")
        case "keys.recovery_key":
            return String(localized: "That isn't your recovery key. Check each group and try again.")
        case "sync.device_removed":
            return String(localized: "This device was removed from your account. Sign out, then sign in again.")
        case "sync.device_not_approved":
            return String(localized: "This device isn't approved for your keys yet.")
        case "sync.locked":
            return String(localized: "This device can no longer read your keys. Approve it again from another device.")
        case "sync.not_allowed":
            return String(localized: "This device can't do that right now.")
        case "sync.step_up_required":
            return String(localized: "Confirm it's you, then try again.")
        case "sync.rate_limited", "sync.restore_check_unavailable", "sync.idempotency_in_progress", "sync.server",
             "sync.use_dpop_nonce", "sync.epoch_changed", "sync.cursor_expired":
            return String(localized: "The server is busy. Try again in a moment.")
        case "sync.network":
            return String(localized: "Could not reach the server. Check your internet connection and try again.")
        case "sync.signed_out", "sync.interactive_sign_in_required":
            return String(localized: "Sign in to TablePro again, then try again.")
        case "sync.feature_required", "sync.seat_required", "sync.license_expired":
            return String(localized: "Your account doesn't include TablePro Sync right now.")
        case "sync.server_too_old":
            return String(localized: "Your server needs an update before this device can use end-to-end encryption.")
        case "sync.not_found", "sync.unknown":
            return String(localized: "That step is no longer open. Start again.")
        case "sync.validation_failed", "sync.idempotency_mismatch", "sync.malformed", "sync.rejected":
            return String(localized: "The server didn't take the change. Try again in a moment.")
        case "sync.unimplemented":
            return String(localized: "This version of TablePro can't do this yet.")
        case "sync.cancelled":
            return generic
        case "sync.device_store.unavailable", "sync.device_store.failed":
            return String(localized: "This device has no place to keep its keys.")
        case "sync.device_store.locked":
            return String(localized: "Unlock this device, then try again.")
        case "keys.stale", "keys.step":
            return String(localized: "Your keys changed on another device. Try again in a moment.")
        case "keys.not_holder":
            return String(localized: "The account that made this key didn't hold the key before it, so this device won't use it.")
        case "keys.conflict":
            return String(localized: "The server offered a key that differs from one this device already checked, so nothing changed.")
        case "keys.sas_mismatch", "keys.commitment":
            return String(localized: "The other device's answer didn't match, so nothing was approved.")
        case "keys.session":
            return String(localized: "This request has ended.")
        case "keys.not_compared":
            return String(localized: "Compare words with that device before it keeps your keys.")
        case "keys.random":
            return String(localized: "This device couldn't make a new key. Try again.")
        default:
            if code.hasPrefix("keys.") {
                return String(localized: "The keys the server sent didn't check out, so nothing changed.")
            }
            if code.hasPrefix("sync.state.") {
                return String(localized: "This device's sync state couldn't be read. Try again in a moment.")
            }
            return generic
        }
    }

    // The code a server gave the change it refused (core ADR 0051, Push).
    private static func rejection(_ code: String) -> String? {
        switch code {
        case "create_only":
            return String(localized: "Another device got there first. Try again in a moment.")
        case "request_closed":
            return String(localized: "This request has ended.")
        case "too_large":
            return String(localized: "Your keys are too large to send to the new device.")
        default:
            return nil
        }
    }

    static func lockTitle(_ cause: LockCauseTag) -> String {
        switch cause {
        case .deviceRemoved: String(localized: "This device was removed from your account")
        case .leftOutOfRotation: String(localized: "Your keys changed without this device")
        case .ownAccountReset: String(localized: "Your account was reset on another device")
        case .accountEnded: String(localized: "Your keys could not be restored")
        case .unanchored: String(localized: "This device's keys can't be checked")
        case .personalStopped: String(localized: "Your personal keys can't be checked")
        }
    }

    static func lockMessage(_ cause: LockCauseTag) -> String {
        switch cause {
        case .deviceRemoved:
            String(localized: "It keeps its keys, but nothing personal syncs here. Sign out, then sign in again and approve this device from another one.")
        case .leftOutOfRotation:
            String(localized: "Another device changed your keys and didn't keep this one. Approve it again from a device that was kept, or use your recovery key.")
        case .ownAccountReset:
            String(localized: "Nothing personal syncs here until the device that reset your account approves this one.")
        case .accountEnded:
            String(localized: "The server lost your keys after a restore. Sign out, then use your recovery key or reset your account.")
        case .unanchored:
            String(localized: "Nothing personal syncs here until another device approves this one or you use your recovery key.")
        case .personalStopped:
            String(localized: "The server showed keys this device couldn't verify, so nothing personal syncs here. Approve it again or use your recovery key.")
        }
    }

    // A locked device asks again only where the lock leaves it a way back on this sign-in.
    static func canAskForApproval(_ cause: LockCauseTag) -> Bool {
        switch cause {
        case .leftOutOfRotation, .ownAccountReset, .unanchored, .personalStopped: true
        case .deviceRemoved, .accountEnded: false
        }
    }

    static func canRecover(_ cause: LockCauseTag) -> Bool {
        switch cause {
        case .leftOutOfRotation, .unanchored, .personalStopped: true
        case .deviceRemoved, .ownAccountReset, .accountEnded: false
        }
    }

    static func deviceName(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return String(localized: "Unnamed device") }
        return name
    }

    static func platform(_ platform: String?) -> String? {
        guard let platform, !platform.isEmpty else { return nil }
        switch platform.lowercased() {
        case "macos": return "macOS"
        case "ios": return "iOS"
        case "ipados": return "iPadOS"
        case "linux": return "Linux"
        case "windows": return "Windows"
        default: return platform
        }
    }

    static func date(microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000)
    }
}

// What a read on the server holds, and whether a read is out or failed. A failed read keeps what was shown.
nonisolated struct AccountRemote<Value: Equatable>: Equatable {
    var value: Value?
    var isLoading = false
    var failure: String?
}

nonisolated struct AccountActionFailure: Equatable, Identifiable {
    let title: String
    let message: String

    var id: String { title + message }
}
