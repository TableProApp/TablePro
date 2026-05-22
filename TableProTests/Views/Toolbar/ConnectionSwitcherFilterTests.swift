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

    @Test("Host is searched")
    func hostMatch() {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "analytics")
        #expect(ConnectionSwitcherFilter.matches(connection, query: "localhost"))
    }

    @Test("Non-matching query returns false")
    func noMatch() {
        let connection = TestFixtures.makeConnection(name: "Primary", database: "analytics")
        #expect(!ConnectionSwitcherFilter.matches(connection, query: "zzz"))
    }
}

@Suite("Connection Switcher Selection")
struct ConnectionSwitcherSelectionTests {
    @Test("Empty list yields no selection")
    func emptyList() {
        #expect(ConnectionSwitcherSelection.moved(in: [], from: nil, by: 1) == nil)
    }

    @Test("Moving down advances to the next id")
    func movesDown() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: a, by: 1) == b)
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: b, by: 1) == c)
    }

    @Test("Moving up retreats to the previous id")
    func movesUp() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: c, by: -1) == b)
    }

    @Test("Moving past the top clamps to the first id")
    func clampsAtTop() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: a, by: -1) == a)
    }

    @Test("Moving past the bottom clamps to the last id")
    func clampsAtBottom() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        #expect(ConnectionSwitcherSelection.moved(in: [a, b, c], from: c, by: 1) == c)
    }
}
