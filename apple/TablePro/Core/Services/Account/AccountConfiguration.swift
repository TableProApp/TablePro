//
//  AccountConfiguration.swift
//  TablePro
//

import CryptoKit
import Foundation

internal struct AccountConfiguration: Sendable {
    static let clientID = "tablepro-macos"
    static let callbackScheme = "app.tablepro"
    static let redirectURI = "app.tablepro:/oauth/callback"
    static let scope = "openid email offline_access app"

    // The production server's entitlement keys, kid to base64url Ed25519 x.
    // A new key ships here a release before the server signs with it (api.md, Entitlement token).
    static let productionEntitlementKeys: [String: String] = [
        "wLT5qcqj3sxp-0NB_21spMxboiyTAW1BwmsXhhgA-XA": "0ozC4TYUqinr-4JfyglENxCUuxFf-90uni0M0sCMR9g"
    ]

    let accountURL: URL
    let apiURL: URL
    let entitlementKeys: [Curve25519.Signing.PublicKey]

    static let production = AccountConfiguration(
        accountURL: URL(string: "https://account.tablepro.app")!,
        apiURL: URL(string: "https://api.tablepro.app")!,
        entitlementKeys: publicKeys(Array(productionEntitlementKeys.values))
    )

    var apiServerURL: URL {
        apiURL.appendingPathComponent("v2")
    }

    var tokenEndpoint: URL {
        accountURL.appendingPathComponent("oauth/token")
    }

    var revocationEndpoint: URL {
        accountURL.appendingPathComponent("oauth/revoke")
    }

    var authorizationEndpoint: URL {
        accountURL.appendingPathComponent("oauth/authorize")
    }

    static func publicKeys(_ values: [String]) -> [Curve25519.Signing.PublicKey] {
        values.compactMap { value in
            Base64URL.decode(value).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        }
    }

    static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> AccountConfiguration {
        #if DEBUG
        return production.overridden(by: environment)
        #else
        return production
        #endif
    }

    // A Debug build run from Xcode can point at a local tablepro-cloud; Release ignores these.
    func overridden(by environment: [String: String]) -> AccountConfiguration {
        let keys = environment["TABLEPRO_ENTITLEMENT_KEYS"].map {
            Self.publicKeys($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        return AccountConfiguration(
            accountURL: environment["TABLEPRO_ACCOUNT_URL"].flatMap(URL.init(string:)) ?? accountURL,
            apiURL: environment["TABLEPRO_API_URL"].flatMap(URL.init(string:)) ?? apiURL,
            entitlementKeys: entitlementKeys + (keys ?? [])
        )
    }
}

// Pages of the account portal (tablepro-cloud web/apps/portal/src/routes).
extension AccountConfiguration {
    var portalBilling: URL {
        accountURL.appendingPathComponent("billing")
    }

    var portalDevices: URL {
        accountURL.appendingPathComponent("devices")
    }

    func portalTeam(_ teamID: String) -> URL {
        accountURL.appendingPathComponent("teams").appendingPathComponent(teamID)
    }

    func portalTeamBilling(_ teamID: String) -> URL {
        portalTeam(teamID).appendingPathComponent("billing")
    }
}
