//
//  AccountPortal.swift
//  TablePro
//

import Foundation

// Pages of the account portal on the server the core signs in to (tablepro-cloud web/apps/portal/src/routes).
internal struct AccountPortal: Equatable, Sendable {
    let accountURL: URL

    init(server: AccountServer) {
        accountURL = server.accountOrigin
    }

    var portalBilling: URL {
        accountURL.appendingPathComponent("billing")
    }

    var portalDevices: URL {
        accountURL.appendingPathComponent("devices")
    }

    var portalSharedLinks: URL {
        accountURL.appendingPathComponent("shared-links")
    }

    func portalTeam(_ teamID: String) -> URL {
        accountURL.appendingPathComponent("teams").appendingPathComponent(teamID)
    }

    func portalTeamBilling(_ teamID: String) -> URL {
        portalTeam(teamID).appendingPathComponent("billing")
    }
}
