//
//  AccountError+Presentation.swift
//  TablePro
//

import Foundation

extension AccountError {
    // Nil when there is nothing to say, as after the person closed the sign-in sheet.
    var friendlyDescription: String? {
        switch self {
        case .canceled:
            return nil
        case .network:
            return String(localized: "Could not reach the license server. Check your internet connection and try again.")
        case .server(let status, _):
            return String(format: String(localized: "Something went wrong (error %d). Try again in a moment."), status)
        case .signedOut, .oauth, .invalidResponse, .stateMismatch, .entitlementRejected:
            return String(localized: "Could not read the server response. Try again in a moment.")
        }
    }
}
