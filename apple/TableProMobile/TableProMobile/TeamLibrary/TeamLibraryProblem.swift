import Foundation
import os
import TableProFFI
import TableProLogRedaction

// What a Team Library read, publish or refused edit failed with, by the engine's code (core ADR 0051, Whole-request
// refusals), as the Mac's TeamLibraryFailure reads it.
nonisolated enum TeamLibraryProblem: Error, Equatable, Sendable {
    case offline
    case rateLimited
    case server
    case signedOut
    // No seat, the team's plan lacks team_library, or the team is gone: the library is not this account's to read.
    case unreadable
    case writeForbidden
    // Past the license's grace the server takes no edits; pulls go on, and the edits wait on this device.
    case licenseExpired
    // The server refused the change as sent; sending it again changes nothing.
    case refused
    // The last account's Team Library data is not deleted yet, so nothing of it is read or sent.
    case deletePending
    case unavailable

    init(code: String) {
        switch code {
        case "sync.network", "sync.team_library.not_pulled":
            self = .offline
        case "sync.rate_limited":
            self = .rateLimited
        case "sync.server", "sync.restore_check_unavailable", "sync.idempotency_in_progress":
            self = .server
        case "sync.signed_out", "sync.interactive_sign_in_required", "sync.device_removed",
             "sync.team_library.signed_in_changed":
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
        if let problem = error as? TeamLibraryProblem {
            self = problem
        } else if case .Failed(let info)? = error as? CoreError {
            self.init(code: info.code)
        } else {
            self = .unavailable
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

    var message: String {
        switch self {
        case .offline:
            String(localized: "Team Library can't be reached. Your edits stay on this device and go once you're online.")
        case .rateLimited:
            String(localized: "The server is busy. Team Library tries again shortly.")
        case .server:
            String(localized: "The server couldn't take this right now. Try again in a moment.")
        case .signedOut:
            String(localized: "Sign in to your TablePro account again to use Team Library.")
        case .unreadable:
            String(localized: "Your account no longer includes this team's library.")
        case .writeForbidden:
            String(localized: "Your role on this team can read its library but not change it.")
        case .licenseExpired:
            String(localized: "The team's license has ended. Its library still downloads, and your edits wait on this device.")
        case .refused:
            String(localized: "The server refused this change. Sending it again changes nothing.")
        case .deletePending:
            String(localized: "The last account's Team Library data is still on this device. Try again in a moment.")
        case .unavailable:
            String(localized: "Team Library isn't available right now.")
        }
    }
}

nonisolated enum TeamLibraryLog {
    // The code is public; the detail, which can name a server or a record, stays private.
    static func code(of error: any Error) -> String {
        if case .Failed(let info)? = error as? CoreError {
            return info.code
        }
        return LogRedaction.publicDescription(of: error)
    }

    static func failure(_ logger: Logger, _ what: String, _ error: any Error) {
        logger.error("\(what, privacy: .public): \(code(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
    }
}
