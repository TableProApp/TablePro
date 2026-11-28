//
//  TeamKeysPresentation.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProPluginKit

// What the team key status row says and offers. The order is the order of precedence: an ended or stopped team key
// says so before anything else about it.
internal enum TeamKeyStatus: Equatable {
    case ended
    case stoppedCatchUp(version: UInt32?)
    case restoreWait
    case restartHeld
    case noKeys(canCreate: Bool)
    case noHolderLeft(canRestart: Bool)
    case awaitingConfirmation
    case rotationDue
    case holder(version: UInt32)
}

internal enum TeamMemberAction: Equatable {
    case confirm
    case compareKeyChange
}

internal enum TeamKeyNoticeAction: Equatable {
    case compareKeyChange(account: String)
    case compareRestart
}

internal struct TeamKeyNotice: Equatable, Identifiable {
    let id: String
    let text: String
    let severity: NoticeSeverity
    let action: TeamKeyNoticeAction?
}

internal enum TeamKeysPresentation {
    static func status(_ snapshot: TeamKeysSnapshot, team: TeamKeysTeam) -> TeamKeyStatus {
        switch snapshot.state {
        case .ended:
            return .ended
        case .stopped:
            switch snapshot.stoppedCause {
            case .restartHeld: return .restartHeld
            case .restoreWait: return .restoreWait
            case .catchUp, nil: return .stoppedCatchUp(version: snapshot.version)
            }
        case .ok:
            break
        }
        guard let version = snapshot.version else {
            return .noKeys(canCreate: team.role == .owner)
        }
        // 0056, Teams, No holder left: only an owner restarts, and only while no one on the roster holds the key.
        if !snapshot.holder, !snapshot.members.contains(where: { $0.status == .holder }) {
            return .noHolderLeft(canRestart: team.role == .owner)
        }
        if !snapshot.holder {
            return .awaitingConfirmation
        }
        return snapshot.rotationDue ? .rotationDue : .holder(version: version)
    }

    // Wrapping the current version is a write under the team key, so a stopped Mac and a non-holder confirm no one.
    static func canWrapCurrentVersion(_ snapshot: TeamKeysSnapshot, team: TeamKeysTeam) -> Bool {
        team.managesKeys && snapshot.state == .ok && snapshot.holder && snapshot.version != nil
    }

    static func action(for member: TeamMemberKeys, in snapshot: TeamKeysSnapshot, team: TeamKeysTeam) -> TeamMemberAction? {
        guard !member.isYou else { return nil }
        switch member.status {
        case .alert:
            return .compareKeyChange
        case .awaitingConfirmation:
            return canWrapCurrentVersion(snapshot, team: team) ? .confirm : nil
        case .holder, .noKeys:
            return nil
        }
    }

    // Owners can restart with no member at all, so the restart lists only those who could take a wrap. A member under
    // a key-change alert takes none until this Mac accepts the new key (0056, Pins), so it is left out until then.
    static func restartCandidates(_ snapshot: TeamKeysSnapshot) -> [TeamMemberKeys] {
        snapshot.members.filter { !$0.isYou && ($0.status == .awaitingConfirmation || $0.status == .holder) }
    }

    static func restartWaitsForKeyChange(_ snapshot: TeamKeysSnapshot) -> [TeamMemberKeys] {
        snapshot.members.filter { !$0.isYou && $0.status == .alert }
    }

    static func statusText(of member: TeamMemberKeys) -> String {
        switch member.status {
        case .holder: String(localized: "Confirmed")
        case .awaitingConfirmation: String(localized: "Waiting for confirmation")
        case .noKeys: String(localized: "Waiting for this person to set up their keys")
        case .alert: String(localized: "Keys changed")
        }
    }

    static func roleName(_ role: TeamRoleTag) -> String {
        switch role {
        case .owner: String(localized: "Owner")
        case .admin: String(localized: "Admin")
        case .editor: String(localized: "Editor")
        case .member: String(localized: "Member")
        }
    }

    static func memberTitle(_ member: TeamMemberKeys) -> String {
        member.isYou ? String(format: String(localized: "%@ (You)"), member.displayName) : member.displayName
    }

    // A driver's own secret is `plugin.<field id>`, named by the label that driver gives the field.
    static func secretName(_ fieldKey: String, driverLabel: (String) -> String?) -> String {
        switch fieldKey {
        case "password": return String(localized: "Password")
        case "ssh_password": return String(localized: "SSH password")
        case "ssh_totp_secret": return String(localized: "SSH one-time code secret")
        default:
            guard fieldKey.hasPrefix("plugin.") else { return String(localized: "Secret") }
            return driverLabel(String(fieldKey.dropFirst("plugin.".count))) ?? String(localized: "Secret")
        }
    }

    // The label the connection's driver gives that secure field, while the driver is known on this Mac.
    static func driverFieldLabel(_ fieldID: String, driver: String?, registry: PluginMetadataRegistry = .shared) -> String? {
        guard let driver else { return nil }
        return registry.snapshot(for: DatabaseType(rawValue: driver))?.connection.additionalConnectionFields
            .first { $0.id == fieldID && $0.isSecure }?.label
    }

    // The notices about this team and its members. A stopped or ended team key shows in the status row instead.
    static func notices(_ notices: [KeyNoticeInfo], team: TeamKeysTeam, snapshot: TeamKeysSnapshot?) -> [TeamKeyNotice] {
        notices.compactMap { notice -> TeamKeyNotice? in
            switch notice.kind {
            case .keysChanged(let account):
                guard let member = snapshot?.member(account) else { return nil }
                return TeamKeyNotice(
                    id: notice.id,
                    text: String(
                        format: String(localized: "%@'s keys changed. Compare their words before sharing team keys with them."),
                        member.displayName
                    ),
                    severity: .warning,
                    action: .compareKeyChange(account: account)
                )
            case .recoveryKeyReplaced(let account):
                guard let member = snapshot?.member(account) else { return nil }
                return TeamKeyNotice(
                    id: notice.id,
                    text: String(format: String(localized: "%@ replaced their recovery key."), member.displayName),
                    severity: .info,
                    action: nil
                )
            case .teamKeyRestarted(let scope) where scope == team.id:
                return TeamKeyNotice(
                    id: notice.id,
                    text: String(localized: "The team key was started over."),
                    severity: .info,
                    action: nil
                )
            case .restartHeld(let scope, let signer) where scope == team.id:
                return TeamKeyNotice(
                    id: notice.id,
                    text: restartHeldText(signer: snapshot?.member(signer)),
                    severity: .warning,
                    action: .compareRestart
                )
            case .supersededWrap(let scope) where scope == team.id:
                return TeamKeyNotice(
                    id: notice.id,
                    text: String(
                        localized: """
                            A teammate's Mac sent the team key to your old keys, so TablePro shared your current keys with the team again. \
                            The server may have kept your key change from that teammate.
                            """
                    ),
                    severity: .warning,
                    action: nil
                )
            case .conflict(let scope) where scope == team.id:
                return TeamKeyNotice(
                    id: notice.id,
                    text: String(
                        localized: "The server offered a team key that differs from one this Mac already checked. This Mac stopped using this team's keys."
                    ),
                    severity: .error,
                    action: nil
                )
            default:
                return nil
            }
        }
    }

    static func restartHeldText(signer: TeamMemberKeys?) -> String {
        guard let signer else {
            return String(
                localized: "Someone who is not on this team started the team key over. Don't accept it unless an owner tells you why."
            )
        }
        return String(
            format: String(localized: "%@ started the team key over. Compare their words before this Mac uses it."),
            signer.displayName
        )
    }
}

// The words a key flow's failure shows. Nil for a cancel, which shows nothing.
@MainActor
internal enum TeamKeysFailureText {
    static func message(_ error: any Error) -> String? {
        if let stepUp = StepUpRetry.failure(error) {
            switch stepUp {
            case .canceled: return nil
            case .failed(let message): return message
            }
        }
        if error is KeyServiceUnavailable {
            return String(localized: "Sign in to your TablePro account to use end-to-end keys.")
        }
        guard let error = error as? CoreError else { return generic }
        guard case .Failed(let info) = error else { return nil }
        if case .rejected(let code)? = info.sync {
            return rejected(code)
        }
        return message(code: info.code)
    }

    private static var generic: String {
        String(localized: "Something went wrong. Try again.")
    }

    static func message(code: String) -> String {
        switch code {
        case "sync.cancelled":
            return generic
        case "sync.unimplemented":
            return String(localized: "End-to-end keys are not available in this build yet.")
        case "sync.network":
            return String(localized: "TablePro couldn't reach the server. Check your connection and try again.")
        case "sync.server", "sync.rate_limited", "sync.restore_check_unavailable", "sync.idempotency_in_progress":
            return String(localized: "The server couldn't take this right now. Try again in a moment.")
        case "sync.signed_out", "sync.interactive_sign_in_required":
            return String(localized: "Sign in to your TablePro account again, then try again.")
        case "sync.device_removed":
            return String(localized: "This Mac was removed from your account. Sign in again to use your keys.")
        case "sync.device_not_approved":
            return String(localized: "Approve this Mac from another of your devices first.")
        case "sync.locked":
            return String(localized: "This Mac is locked. Approve it again from another of your devices.")
        case "sync.not_allowed":
            return String(localized: "This Mac can't do that right now.")
        case "sync.typed_back_wrong":
            return String(localized: "The groups you typed don't match the recovery key. Check them and try again.")
        case "sync.unknown":
            return String(localized: "That step is no longer open. Start again.")
        case "keys.not_holder":
            return String(localized: "The account that made this team key didn't hold the key before it, so this Mac won't use it.")
        case "keys.stale":
            return String(localized: "This Mac's keys are behind. Wait for it to sync, then try again.")
        case "keys.conflict":
            return String(localized: "The server offered a key that differs from one this Mac already checked, so nothing changed.")
        case "keys.recovery_key":
            return String(localized: "That isn't a valid recovery key. Check it and try again.")
        default:
            if code.hasPrefix("keys.") {
                return String(localized: "The keys the server sent didn't check out, so nothing changed.")
            }
            return generic
        }
    }

    static func rejected(_ code: String) -> String {
        switch code {
        case "create_only":
            return String(localized: "Someone else made this change at the same time. The latest state is shown.")
        case "role":
            return String(localized: "Your role on this team doesn't allow this.")
        case "team_full":
            return String(localized: "5,000 members of this team already hold its key. An admin needs to split the team.")
        case "key_dependency":
            return String(localized: "This person hasn't shared their keys with the team yet. Try again later.")
        case "rotation_due":
            return String(localized: "The team key needs to be rotated first.")
        case "reset_held":
            return String(localized: "The reset can't finish before its waiting period ends.")
        case "request_closed":
            return String(localized: "That step is no longer open. Start again.")
        default:
            return String(localized: "The server refused the change. Try again.")
        }
    }
}
