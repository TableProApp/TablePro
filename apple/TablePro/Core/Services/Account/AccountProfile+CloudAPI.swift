//
//  AccountProfile+CloudAPI.swift
//  TablePro
//

import Foundation
import TableProCloudAPI

extension AccountProfile {
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

    static func read(_ output: Operations.GetMe.Output) throws -> AccountProfile {
        switch output {
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
    }
}

// /v2 answers carry open strings: a code a newer server adds stays as sent, and AccountCodes shows it neutrally.
internal enum OpenCode {
    static func of(_ value: String) -> String {
        value
    }
}
