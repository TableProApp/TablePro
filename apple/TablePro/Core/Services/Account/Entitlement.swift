//
//  Entitlement.swift
//  TablePro
//

import Foundation

internal struct EntitlementLicense: Equatable, Sendable {
    struct Team: Equatable, Sendable {
        let id: String
        let name: String
    }

    let id: String
    let plan: String
    let cycle: String
    let source: String
    let status: String
    let endsAt: Date?
    let team: Team?
}

internal struct Entitlement: Equatable, Sendable {
    let token: String
    let accountID: String
    let deviceID: String
    let machineID: String
    let features: Set<String>
    let licenses: [EntitlementLicense]
    let email: String
    let name: String?
    let issuedAt: Date
    let notBefore: Date
    let expiresAt: Date
    let isOffline: Bool

    func isValid(at now: Date) -> Bool {
        notBefore <= now.addingTimeInterval(EntitlementVerifier.notBeforeLeeway) && now < expiresAt
    }
}

extension Entitlement {
    struct Claims: Decodable {
        struct License: Decodable {
            struct Team: Decodable {
                let id: String
                let name: String
            }

            let id: String
            let plan: String
            let cycle: String
            let source: String
            let status: String
            let endsAt: String?
            let team: Team?

            enum CodingKeys: String, CodingKey {
                case id, plan, cycle, source, status, team
                case endsAt = "ends_at"
            }
        }

        struct Account: Decodable {
            let email: String
            let name: String?
        }

        let aud: String
        let sub: String
        let iat: Int64
        let nbf: Int64
        let exp: Int64
        let dev: String
        let mid: String
        let features: [String]
        let licenses: [License]?
        let account: Account?
        let offline: Bool?
    }

    init(token: String, claims: Claims) throws(EntitlementVerifier.Failure) {
        var licenses: [EntitlementLicense] = []
        for license in claims.licenses ?? [] {
            var endsAt: Date?
            if let text = license.endsAt {
                guard let date = try? Date(text, strategy: .iso8601) else { throw .malformed }
                endsAt = date
            }
            licenses.append(EntitlementLicense(
                id: license.id,
                plan: license.plan,
                cycle: license.cycle,
                source: license.source,
                status: license.status,
                endsAt: endsAt,
                team: license.team.map { EntitlementLicense.Team(id: $0.id, name: $0.name) }
            ))
        }
        let name = claims.account?.name ?? ""
        self.init(
            token: token,
            accountID: claims.sub,
            deviceID: claims.dev,
            machineID: claims.mid,
            features: Set(claims.features),
            licenses: licenses,
            email: claims.account?.email ?? "",
            name: name.isEmpty ? nil : name,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(claims.iat)),
            notBefore: Date(timeIntervalSince1970: TimeInterval(claims.nbf)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(claims.exp)),
            isOffline: claims.offline ?? false
        )
    }
}
