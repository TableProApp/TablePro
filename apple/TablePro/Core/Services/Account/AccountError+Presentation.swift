//
//  AccountError+Presentation.swift
//  TablePro
//

import Foundation

extension AccountError {
    // Nil when there is nothing to say: the person closed the sign-in sheet or declined on the confirmation screen.
    var friendlyDescription: String? {
        switch self {
        case .canceled, .oauth("access_denied", _):
            return nil
        case .network:
            return String(localized: "Could not reach the license server. Check your internet connection and try again.")
        case .oauth("temporarily_unavailable", _):
            return String(localized: "The server is busy. Try again in a few minutes.")
        case .signedOut:
            return String(localized: "You were signed out. Sign in again.")
        case .server(let status, _):
            return String(format: String(localized: "Something went wrong (error %d). Try again in a moment."), status)
        case .oauth, .invalidResponse, .stateMismatch, .entitlementRejected:
            return String(localized: "Could not read the server response. Try again in a moment.")
        }
    }
}
