//
//  TeamRoleTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("TeamRole")
struct TeamRoleTests {
    @Test("The roles the server writes are recognised, whatever their casing")
    func knownRolesDecode() {
        #expect(TeamRole(rawValue: "owner") == .owner)
        #expect(TeamRole(rawValue: "Owner") == .owner)
        #expect(TeamRole(rawValue: " ADMIN ") == .admin)
        #expect(TeamRole(rawValue: "member") == .member)
    }

    @Test("A role this build has never heard of survives instead of being dropped")
    func unknownRoleRoundTrips() {
        let role = TeamRole(rawValue: "auditor")
        #expect(role == .unknown("auditor"))
        #expect(role.displayName == "Auditor")
    }

    @Test("Every role has something to show for itself")
    func everyRoleHasADisplayName() {
        let roles: [TeamRole] = [.owner, .admin, .member, .unknown("reviewer")]
        for role in roles {
            #expect(role.displayName.isEmpty == false)
        }
    }
}
