//
//  AccountError.swift
//  TablePro
//

import Foundation

nonisolated internal enum AccountError: Error, Equatable {
    enum OfflineFileProblem: Equatable, Sendable {
        case otherMachine
        // Another account's file, on a Mac signed in to this one.
        case otherAccount
        case expired
        case notYetValid
        case unreadable
    }

    enum CompanyServerProblem: Equatable, Sendable {
        // Not an https origin, or http away from this device.
        case invalidAddress
        // Its metadata or OpenID configuration does not name a TablePro server at this address.
        case notATableProServer
        case licenseMissing
        // The license does not verify with a key this build ships, or names another server.
        case licenseInvalid
        // The organization sets the server, so the person cannot choose another.
        case managed
        // A company server takes neither a license key nor an offline file.
        case unsupported
    }

    case signedOut
    case canceled
    case network(String)
    case oauth(String, description: String?)
    case server(status: Int, code: String?)
    case invalidResponse
    case offlineFileRejected(OfflineFileProblem)
    case companyServer(CompanyServerProblem)
    // Another account or server while signed in: that goes through Sign Out, which asks about unsent Team Library edits.
    case signOutFirst
}

nonisolated extension AccountError {
    var problemCode: String? {
        guard case .server(_, let code) = self else { return nil }
        return code
    }
}
