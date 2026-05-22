//
//  ConnectionSwitcherFilterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Connection Switcher Filter")
struct ConnectionSwitcherFilterTests {
    @Test("Empty or whitespace query matches every connection")
    func emptyQueryMatches() {
        let connection = TestFixtures.makeConnection(name: "Production", database: "app")
        #expect(ConnectionSwitcherFilter.matches(connection, query: ""))
        #expect(ConnectionSwitcherFilter.matches(connection, query: "   "))
    }

    @Test("Name match is case-insensitive and substring-based")
    func nameMatchCaseInsensitive() {
        let connection = TestFixtures.makeConnection(name: "Production DB", database: "app")
        #expect(ConnectionSwitcherFilter.matches(connection, query: "prod"))
        #expect(ConnectionSwitcherFilter.matches(connection, query: "DB"))
    }

    @Test("Database name is searched")
    func databaseMatch() {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "analytics")
        #expect(ConnectionSwitcherFilter.matches(connection, query: "analy"))
    }

    @Test("Non-matching query returns false")
    func noMatch() {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "analytics")
        #expect(!ConnectionSwitcherFilter.matches(connection, query: "zzz"))
    }
}
