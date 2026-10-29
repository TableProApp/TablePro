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

extension AccountError {
    var licenseKeyDescription: String? {
        switch self {
        case .oauth("invalid_grant", _):
            return String(localized: "This license key is not valid, or its license was revoked.")
        case .oauth("invalid_request", _):
            return String(localized: "Check the license key and try again.")
        default:
            return friendlyDescription
        }
    }

    var offlineFileDescription: String? {
        switch self {
        case .entitlementRejected(.machine):
            return String(localized: "This offline file was made for another machine. Create one for this Mac's machine ID.")
        case .entitlementRejected(.expired):
            return String(localized: "This offline file has expired. Create a new one in your account.")
        case .entitlementRejected(.notYetValid):
            return String(localized: "This offline file is not valid yet. Check this Mac's date and time.")
        case .entitlementRejected, .invalidResponse:
            return String(localized: "This file is not a TablePro offline file, or it is damaged.")
        default:
            return friendlyDescription
        }
    }

    var deviceRemovalDescription: String? {
        switch self {
        case .server(_, "offline_file_active"):
            return String(localized: "This device has a valid offline file, so it keeps its license slot until the file expires.")
        case .server(_, "not_found"):
            return String(localized: "This device was already removed.")
        default:
            return friendlyDescription
        }
    }
}
