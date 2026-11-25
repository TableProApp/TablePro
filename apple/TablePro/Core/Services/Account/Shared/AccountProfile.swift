//
//  AccountProfile.swift
//  TablePro
//

import Foundation

nonisolated internal struct AccountMembership: Equatable, Sendable, Identifiable {
    let teamID: String
    let teamName: String
    let role: String
    let hasSeat: Bool

    var id: String { teamID }

    // The roles tablepro-cloud lets write a team's library. The server still refuses a push it does not allow.
    var writesTeamLibrary: Bool {
        role == "owner" || role == "admin" || role == "editor"
    }
}

// GET /v2/me: who is signed in and the teams the account belongs to, with its role and seat in each.
nonisolated internal struct AccountProfile: Equatable, Sendable {
    let email: String
    let name: String?
    let memberships: [AccountMembership]
}
