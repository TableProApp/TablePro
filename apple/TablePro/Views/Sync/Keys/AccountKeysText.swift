//
//  AccountKeysText.swift
//  TablePro
//

import Foundation
import TableProFFI

// The words the end-to-end screens use for what the core answers by code (core AGENTS.md, Errors carry a code).
internal enum AccountKeysText {
    static func message(for error: any Error) -> String {
        if let error = error as? AccountError {
            return error.friendlyDescription ?? String(localized: "Something went wrong. Try again.")
        }
        guard case .Failed(let info)? = error as? CoreError else {
            return String(localized: "Something went wrong. Try again.")
        }
        if case .rejected(let code)? = info.sync, let message = rejection(code) {
            return message
        }
        if case .locked(let cause)? = info.sync {
            return lockMessage(cause)
        }
        switch info.code {
        case "sync.typed_back_wrong":
            return String(localized: "Those groups don't match your recovery key. Check them and try again.")
        case "keys.recovery_key":
            return String(localized: "That isn't your recovery key. Check each group and try again.")
        case "sync.device_removed":
            return String(localized: "This Mac was removed from your account. Sign out, then sign in again.")
        case "sync.device_not_approved":
            return String(localized: "This Mac isn't approved for your keys yet.")
        case "sync.step_up_required":
            return String(localized: "Confirm it's you, then try again.")
        case "sync.rate_limited", "sync.restore_check_unavailable":
            return String(localized: "The server is busy. Try again in a moment.")
        case "sync.network":
            return String(localized: "Could not reach the server. Check your connection and try again.")
        case "sync.signed_out", "sync.interactive_sign_in_required":
            return String(localized: "Sign in to TablePro again, then try again.")
        case "keys.stale", "keys.step":
            return String(localized: "Your keys changed on another device. Try again in a moment.")
        case "sync.unimplemented":
            return String(localized: "This version of TablePro can't do this yet.")
        default:
            return String(format: String(localized: "Something went wrong (%@). Try again."), info.code)
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
        case .deviceRemoved: String(localized: "This Mac was removed from your account")
        case .leftOutOfRotation: String(localized: "Your keys changed without this Mac")
        case .ownAccountReset: String(localized: "Your account was reset on another device")
        case .accountEnded: String(localized: "Your keys could not be restored")
        case .unanchored: String(localized: "This Mac's keys can't be checked")
        case .personalStopped: String(localized: "Your personal keys can't be checked")
        }
    }

    static func lockMessage(_ cause: LockCauseTag) -> String {
        switch cause {
        case .deviceRemoved:
            String(localized: "It keeps its keys, but nothing personal syncs here. Sign out, then sign in again and approve this Mac from another device.")
        case .leftOutOfRotation:
            String(localized: "Another device changed your keys and didn't keep this Mac. Approve it again from a device that was kept, or use your recovery key.")
        case .ownAccountReset:
            String(localized: "Nothing personal syncs here until the device that reset your account approves this Mac.")
        case .accountEnded:
            String(localized: "The server lost your keys after a restore. Sign out, then use your recovery key or reset your account.")
        case .unanchored:
            String(localized: "Nothing personal syncs here until another device approves this Mac or you use your recovery key.")
        case .personalStopped:
            String(localized: "The server showed keys this Mac couldn't verify, so nothing personal syncs here. Approve it again or use your recovery key.")
        }
    }

    // A locked Mac asks again only where the lock leaves it a way back on this sign-in.
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
