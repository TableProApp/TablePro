//
//  TeamLibraryFailure.swift
//  TablePro
//

import Foundation
import TableProFFI

internal enum TeamLibraryFailure: Error, Equatable, Sendable {
    case offline
    case rateLimited
    case server
    case signedOut
    // No seat, the team's plan lacks team_library, or the team is gone: the library is not this account's to read.
    case unreadable
    case writeForbidden
    // Past the license's grace the server takes no edits; pulls go on, and the edits wait on this Mac.
    case licenseExpired
    // The server refused the change as sent; sending it again changes nothing.
    case refused
    // The last account's Team Library data is not deleted yet, so nothing of it is read or sent.
    case deletePending
    case unavailable

    // The engine's code for a pass, a publish or a refused edit (core ADR 0051, Whole-request refusals).
    init(code: String) {
        switch code {
        case "sync.network", "sync.team_library.not_pulled":
            self = .offline
        case "sync.rate_limited":
            self = .rateLimited
        case "sync.server", "sync.restore_check_unavailable", "sync.idempotency_in_progress":
            self = .server
        case "sync.signed_out", "sync.interactive_sign_in_required", "sync.device_removed",
             "sync.team_library.signed_in_changed", "sync.team_library.other_owner":
            self = .signedOut
        case "sync.feature_required", "sync.seat_required", "sync.team_library.unknown_team":
            self = .unreadable
        case "sync.team_library.not_writable", "role", "library_write_forbidden":
            self = .writeForbidden
        case "sync.license_expired", "sync.team_library.pull_only", "license_expired":
            self = .licenseExpired
        case "sync.team_library.delete_pending", "sync.team_library.delete_failed":
            self = .deletePending
        case "sync.unimplemented", "sync.not_allowed":
            self = .unavailable
        default:
            self = .refused
        }
    }

    init(_ error: any Error) {
        if case .Failed(let info) = error as? CoreError {
            self.init(code: info.code)
        } else {
            self = .unavailable
        }
    }

    var logName: String {
        switch self {
        case .offline: "offline"
        case .rateLimited: "rateLimited"
        case .server: "server"
        case .signedOut: "signedOut"
        case .unreadable: "unreadable"
        case .writeForbidden: "writeForbidden"
        case .licenseExpired: "licenseExpired"
        case .refused: "refused"
        case .deletePending: "deletePending"
        case .unavailable: "unavailable"
        }
    }

    // The engine tries these again on its own schedule.
    var isRetryable: Bool {
        switch self {
        case .offline, .rateLimited, .server:
            true
        case .signedOut, .unreadable, .writeForbidden, .licenseExpired, .refused, .deletePending, .unavailable:
            false
        }
    }
}
