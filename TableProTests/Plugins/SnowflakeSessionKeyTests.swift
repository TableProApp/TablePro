//
//  SnowflakeSessionKeyTests.swift
//  TableProTests
//
//  Tests for SnowflakeSessionKey (compiled via symlink from SnowflakeDriverPlugin).
//

import Foundation
import Testing

@Suite("Snowflake Session Key")
struct SnowflakeSessionKeyTests {
    private func key(
        connectionId: String = "A",
        host: String = "acct.snowflakecomputing.com",
        user: String = "dana",
        authMethod: String = "password",
        role: String = "analyst"
    ) -> String {
        SnowflakeSessionKey.fingerprint(
            connectionId: connectionId,
            host: host,
            user: user,
            authMethod: authMethod,
            role: role
        )
    }

    /// The defect: two saved connections to one account, user and role shared a session, so
    /// `USE DATABASE` in one moved the other's current database and a save wrote to the wrong one.
    @Test("Two saved connections to the same account do not share a session")
    func testDistinctConnectionsDoNotShare() {
        #expect(key(connectionId: "A") != key(connectionId: "B"))
    }

    @Test("The same saved connection always resolves to one session")
    func testSameConnectionShares() {
        #expect(key(connectionId: "A") == key(connectionId: "A"))
    }

    /// The metadata pool rewrites the database on its copy before building a driver, so a key that
    /// varied with the database would give that driver its own login and another MFA prompt.
    @Test("The database is not part of the key")
    func testDatabaseIsNotInTheKey() {
        #expect(!key().contains("ANALYTICS"))
        #expect(key(connectionId: "A") == key(connectionId: "A"))
    }

    @Test("Account identity still separates sessions")
    func testAccountIdentitySeparates() {
        #expect(key(host: "one.snowflakecomputing.com") != key(host: "two.snowflakecomputing.com"))
        #expect(key(user: "dana") != key(user: "sam"))
        #expect(key(authMethod: "password") != key(authMethod: "keyPair"))
        #expect(key(role: "analyst") != key(role: "admin"))
    }

    @Test("User and role compare case-insensitively")
    func testCaseFolding() {
        #expect(key(user: "dana") == key(user: "DANA"))
        #expect(key(role: "analyst") == key(role: "ANALYST"))
    }
}
