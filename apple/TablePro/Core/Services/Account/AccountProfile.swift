//
//  AccountProfile.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

internal struct AccountMembership: Equatable, Sendable, Identifiable {
    let teamID: String
    let teamName: String
    let role: String
    let hasSeat: Bool

    var id: String { teamID }
}

// GET /v2/me: who is signed in and the teams the account belongs to, with its role and seat in each.
internal struct AccountProfile: Equatable, Sendable {
    let email: String
    let name: String?
    let memberships: [AccountMembership]

    init(email: String, name: String?, memberships: [AccountMembership]) {
        self.email = email
        self.name = name
        self.memberships = memberships
    }

    init(_ me: Components.Schemas.Me) {
        let name = me.account.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(
            email: me.account.email,
            name: name.isEmpty ? nil : name,
            memberships: me.teams.map { membership in
                AccountMembership(
                    teamID: membership.team.id,
                    teamName: membership.team.name,
                    role: OpenCode.of(membership.role),
                    hasSeat: membership.hasSeat
                )
            }
        )
    }

    static func fetch(api: any APIProtocol) async throws(AccountError) -> AccountProfile {
        do {
            switch try await api.getMe() {
            case .ok(let answer):
                return AccountProfile(try answer.body.json)
            case .unauthorized(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .forbidden(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .tooManyRequests(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .internalServerError(let answer):
                throw AccountError.problem(try answer.body.applicationProblemJson)
            case .undocumented(let status, _):
                throw AccountError.server(status: status, code: nil)
            }
        } catch {
            throw AccountError.from(error)
        }
    }
}

// /v2 answers carry open strings: a code a newer server adds stays as sent, and AccountCodes shows it neutrally.
internal enum OpenCode {
    static func of(_ value: String) -> String {
        value
    }
}
