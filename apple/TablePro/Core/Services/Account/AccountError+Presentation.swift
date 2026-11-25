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
        case .server(let status, _) where status > 0:
            return String(format: String(localized: "Something went wrong (error %d). Try again in a moment."), status)
        // The core passes a server's refusal on by its code alone.
        case .server:
            return String(localized: "The server refused the request. Try again in a moment.")
        case .oauth, .invalidResponse, .offlineFileRejected:
            return String(localized: "Could not read the server response. Try again in a moment.")
        case .otherIssuer:
            return String(localized: "Could not confirm the sign-in came from the server TablePro asked. Sign in again.")
        case .companyServer(let problem):
            return problem.description
        case .signOutFirst:
            return String(localized: "Sign out first, then sign in to the other account or server.")
        }
    }
}

extension AccountError.CompanyServerProblem {
    var description: String {
        switch self {
        case .invalidAddress:
            return String(localized: "Enter the server's https address, such as https://tablepro.example.com.")
        case .notATableProServer:
            return String(localized: "This address does not answer as a TablePro server. Check it with your administrator.")
        case .licenseMissing:
            return String(localized: "This server has no TablePro license installed. Ask your administrator to install one.")
        case .licenseInvalid:
            return String(localized: "This server's TablePro license is not valid for this server. Ask your administrator.")
        case .managed:
            return String(localized: "Your organization manages which server TablePro signs in to.")
        case .unsupported:
            return String(localized: "Your organization's server licenses this Mac. A license key or an offline file is not needed.")
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
        case .offlineFileRejected(.otherMachine):
            return String(localized: "This offline file was made for another machine. Create one for this Mac's machine ID.")
        case .offlineFileRejected(.otherAccount):
            return String(localized: "This offline file is for another account. Sign out first, or create one for the account signed in.")
        case .offlineFileRejected(.expired):
            return String(localized: "This offline file has expired. Create a new one in your account.")
        case .offlineFileRejected(.notYetValid):
            return String(localized: "This offline file is not valid yet. Check this Mac's date and time.")
        case .offlineFileRejected, .invalidResponse:
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
