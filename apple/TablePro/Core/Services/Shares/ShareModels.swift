//
//  ShareModels.swift
//  TablePro
//

import Foundation

internal enum SharePlan: String, Equatable, Sendable {
    case free
    case pro
}

internal enum ShareKind: String, Equatable, Sendable {
    case query
    case result
}

internal enum ShareExpiry: String, CaseIterable, Identifiable, Equatable, Sendable {
    case oneDay = "1d"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneDay: String(localized: "1 day")
        case .sevenDays: String(localized: "7 days")
        case .thirtyDays: String(localized: "30 days")
        case .never: String(localized: "Never")
        }
    }
}

internal struct ShareLimits: Equatable, Sendable {
    let plan: SharePlan
    let live: Int
    let liveLimit: Int
    let maxRows: Int
    let expiries: [ShareExpiry]
    let defaultExpiry: ShareExpiry
    let allowsPassword: Bool
    let allowsDisablingDownload: Bool
    let allowsTeamLinks: Bool
    let emailVerified: Bool
    let sharingDisabled: Bool

    var isAtCap: Bool {
        live >= liveLimit
    }

    func allows(_ expiry: ShareExpiry) -> Bool {
        expiries.contains(expiry)
    }

    func withLive(_ live: Int) -> ShareLimits {
        ShareLimits(
            plan: plan,
            live: live,
            liveLimit: liveLimit,
            maxRows: maxRows,
            expiries: expiries,
            defaultExpiry: defaultExpiry,
            allowsPassword: allowsPassword,
            allowsDisablingDownload: allowsDisablingDownload,
            allowsTeamLinks: allowsTeamLinks,
            emailVerified: emailVerified,
            sharingDisabled: sharingDisabled
        )
    }
}

// Wide integers, and decimals a browser would print differently, are already strings here.
internal enum ShareCell: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
}

internal struct ShareSnapshot: Equatable, Sendable {
    struct Column: Equatable, Sendable {
        let name: String
        let type: String?
    }

    let columns: [Column]
    let rows: [[ShareCell]]
    // The result's true total, at least rows.count.
    let rowCount: Int

    var isTruncated: Bool {
        rowCount > rows.count
    }
}

internal struct ShareDraft: Equatable, Sendable {
    let kind: ShareKind
    let sql: String
    let title: String
    let note: String?
    let dialect: String?
    let expiry: ShareExpiry
    // Sent only for a result; a query share always shows its SQL.
    let hidesSQL: Bool?
    // Sent only to turn downloads off, which needs Pro.
    let allowsDownload: Bool?
    let password: String?
    let snapshot: ShareSnapshot?
}

internal struct CreatedShare: Equatable, Sendable {
    let id: String
    let url: URL
}

internal struct ShareLink: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: ShareKind
    let createdAt: Date
    let expiresAt: Date?
}

internal struct SharedQuery: Equatable, Sendable {
    let kind: ShareKind
    let title: String
    // Nil when the owner hid the SQL of a result share.
    let sql: String?
}

internal enum ShareFailure: Error, Equatable, Sendable {
    case signedOut
    case emailUnverified
    case proRequired
    case sharingDisabled
    case teamSharingDisabled
    case seatRequired
    case notFound
    case limitReached
    case revoked
    case removed
    case snapshotTooLarge
    case invalid
    case rateLimited
    case passwordRequired
    case passwordWrong
    case offline
    case canceled
    case server

    static func problem(status: Int, code: String?) -> ShareFailure {
        switch code {
        case "unauthorized": return .signedOut
        case "email_unverified": return .emailUnverified
        case "pro_required": return .proRequired
        case "sharing_disabled": return .sharingDisabled
        case "team_sharing_disabled": return .teamSharingDisabled
        case "seat_required": return .seatRequired
        case "not_found": return .notFound
        case "share_limit_reached": return .limitReached
        case "share_revoked": return .revoked
        case "share_removed": return .removed
        case "snapshot_too_large": return .snapshotTooLarge
        case "validation_failed": return .invalid
        case "rate_limited": return .rateLimited
        case "share_password_required": return .passwordRequired
        case "share_password_wrong": return .passwordWrong
        default: return httpStatus(status)
        }
    }

    static func httpStatus(_ status: Int) -> ShareFailure {
        switch status {
        case 401: return .signedOut
        case 404: return .notFound
        case 409: return .limitReached
        case 413: return .snapshotTooLarge
        case 422: return .invalid
        case 429: return .rateLimited
        default: return .server
        }
    }

    static func from(_ error: AccountError) -> ShareFailure {
        switch error {
        case .canceled:
            return .canceled
        case .signedOut:
            return .signedOut
        case .network:
            return .offline
        case .server(let status, let code):
            return problem(status: status, code: code)
        case .oauth("invalid_grant", _):
            return .signedOut
        case .oauth, .invalidResponse, .stateMismatch, .entitlementRejected:
            return .server
        }
    }

    // What a create or a load shows, or nil when there is nothing to say.
    var message: String? {
        switch self {
        case .canceled:
            return nil
        case .signedOut:
            return String(localized: "Sign in to your TablePro account to share links.")
        case .emailUnverified:
            return String(localized: "Verify your email address to share links.")
        case .proRequired:
            return String(localized: "This option needs TablePro Pro.")
        case .sharingDisabled:
            return String(localized: "Sharing is turned off for this account.")
        case .teamSharingDisabled:
            return String(localized: "Public links are turned off for this team.")
        case .snapshotTooLarge:
            return String(localized: "This result is too large to share.")
        case .rateLimited:
            return String(localized: "Too many links just now. Try again in a moment.")
        case .offline:
            return String(localized: "You appear to be offline. Try again once you're connected.")
        case .seatRequired, .notFound, .limitReached, .revoked, .removed, .invalid,
             .passwordRequired, .passwordWrong, .server:
            return String(localized: "The link couldn't be created. Try again.")
        }
    }
}
