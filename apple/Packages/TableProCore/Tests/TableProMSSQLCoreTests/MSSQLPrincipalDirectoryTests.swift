import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLPrincipalDirectoryTests {
    private func directory(
        logins: [MSSQLPrincipalDirectory.LoginRow] = [],
        serverRoles: [String] = [],
        databasePrincipals: [MSSQLPrincipalDirectory.DatabasePrincipalRow] = [],
        serverMemberships: [MSSQLPrincipalDirectory.MembershipRow] = [],
        databaseMemberships: [MSSQLPrincipalDirectory.MembershipRow] = []
    ) -> MSSQLPrincipalDirectory {
        MSSQLPrincipalDirectory(
            database: "Sales",
            logins: logins,
            serverRoles: serverRoles,
            databasePrincipals: databasePrincipals,
            serverMemberships: serverMemberships,
            databaseMemberships: databaseMemberships
        )
    }

    @Test func testLoginCarriesTheUserItMapsTo() {
        let directory = directory(logins: [.init(name: "sa", isDisabled: false, user: "dbo")])

        #expect(directory.kind(of: "sa") == .login(user: "dbo"))
        #expect(directory.entry(named: "sa")?.isEnabled == true)
    }

    @Test func testDisabledLoginIsNotEnabled() {
        let directory = directory(logins: [.init(name: "app", isDisabled: true, user: nil)])

        #expect(directory.entry(named: "app")?.isEnabled == false)
        #expect(directory.kind(of: "app") == .login(user: nil))
    }

    @Test func testDatabaseRolesAndUsersWithoutLoginAreListed() {
        let directory = directory(databasePrincipals: [
            .init(name: "readers", isRole: true, hasConnect: false),
            .init(name: "guest", isRole: false, hasConnect: false),
            .init(name: "contained", isRole: false, hasConnect: true)
        ])

        #expect(directory.kind(of: "readers") == .databaseRole)
        #expect(directory.kind(of: "guest") == .databaseUser)
        #expect(directory.entry(named: "guest")?.isEnabled == false)
        #expect(directory.entry(named: "contained")?.isEnabled == true)
    }

    @Test func testSharedNameKeepsTheLogin() {
        let directory = directory(
            logins: [.init(name: "reporting", isDisabled: false, user: nil)],
            serverRoles: ["reporting"],
            databasePrincipals: [.init(name: "reporting", isRole: true, hasConnect: false)]
        )

        #expect(directory.entries.count == 1)
        #expect(directory.kind(of: "reporting") == .login(user: nil))
    }

    @Test func testMembershipOfAMappedUserIsReportedOnItsLogin() {
        let directory = directory(
            logins: [.init(name: "CORP\\alice", isDisabled: false, user: "alice")],
            serverRoles: ["sysadmin"],
            databasePrincipals: [.init(name: "db_datareader", isRole: true, hasConnect: false)],
            serverMemberships: [.init(member: "CORP\\alice", role: "sysadmin")],
            databaseMemberships: [.init(member: "alice", role: "db_datareader")]
        )

        #expect(directory.entry(named: "CORP\\alice")?.memberOf == ["db_datareader", "sysadmin"])
        #expect(directory.members(of: "db_datareader") == ["CORP\\alice"])
    }

    @Test func testRoleNestingIsKeptAtBothLevels() {
        let directory = directory(
            serverRoles: ["auditors", "securityadmin"],
            databasePrincipals: [
                .init(name: "app_read", isRole: true, hasConnect: false),
                .init(name: "db_datareader", isRole: true, hasConnect: false)
            ],
            serverMemberships: [.init(member: "auditors", role: "securityadmin")],
            databaseMemberships: [.init(member: "app_read", role: "db_datareader")]
        )

        #expect(directory.entry(named: "auditors")?.memberOf == ["securityadmin"])
        #expect(directory.entry(named: "app_read")?.memberOf == ["db_datareader"])
    }

    @Test func testMembershipOfAnUnlistedPrincipalIsDropped() {
        let directory = directory(
            databasePrincipals: [.init(name: "db_owner", isRole: true, hasConnect: false)],
            databaseMemberships: [.init(member: "invisible", role: "db_owner")]
        )

        #expect(directory.members(of: "db_owner").isEmpty)
    }
}
