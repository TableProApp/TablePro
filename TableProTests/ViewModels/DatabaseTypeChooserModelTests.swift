//
//  DatabaseTypeChooserModelTests.swift
//  TableProTests
//
//  The chooser's filter matches taglines and category names as well as driver names, so the first
//  row on screen is routinely not the best answer. Arming it would let Return commit a driver the
//  user never looked at, and on an existing connection a type change resets its credentials, SSL,
//  driver options and transport.
//

import Foundation
import Testing

@testable import TablePro

@MainActor
@Suite("Database type chooser model")
struct DatabaseTypeChooserModelTests {
    /// Named explicitly rather than taken from `PluginManager`, which loads no plugins under XCTest.
    private func model() -> DatabaseTypeChooserModel {
        DatabaseTypeChooserModel(types: [.postgresql, .cockroachdb, .pglite, .mysql, .mariadb, .sqlite])
    }

    @Test("a query naming a driver exactly arms that driver, not an alphabetically earlier tagline hit")
    func exactNameOutranksATaglineMatch() {
        let model = model()
        model.searchText = "PostgreSQL"

        #expect(
            model.filteredTypes.contains(.cockroachdb),
            "CockroachDB's tagline mentions PostgreSQL, so it is still a visible result"
        )
        #expect(model.orderedTypes.first != .postgresql, "CockroachDB sorts ahead of it on screen")
        #expect(model.highlightedType == .postgresql, "The armed row must be the driver that was named")
    }

    @Test("MySQL is armed over MariaDB, whose tagline names it")
    func exactNameOutranksAForkTagline() {
        let model = model()
        model.searchText = "MySQL"
        #expect(model.highlightedType == .mysql)
    }

    @Test("a prefix arms the driver it begins")
    func prefixArmsTheDriver() {
        let model = model()
        model.searchText = "postgre"
        #expect(model.highlightedType == .postgresql)
    }

    @Test("a sole match is armed even when only its tagline matched")
    func soleTaglineMatchIsArmed() {
        let model = model()
        model.searchText = "Distributed"

        #expect(model.orderedTypes == [.cockroachdb], "Only CockroachDB's tagline says Distributed")
        #expect(
            model.highlightedType == .cockroachdb,
            "One row is unambiguous, which is the whole point of arming it"
        )
    }

    @Test("several matches with no driver-name hit arm nothing")
    func ambiguousNonNameMatchArmsNothing() {
        let model = model()
        model.searchText = DatabaseCategory.relational.displayName

        #expect(model.orderedTypes.count > 1, "Every relational driver matches on category alone")
        #expect(
            model.orderedTypes.allSatisfy {
                !$0.rawValue.lowercased().contains(DatabaseCategory.relational.displayName.lowercased())
            },
            "None of them matched on its own name"
        )
        #expect(
            model.highlightedType == nil,
            "No row is a defensible default among many, so Continue stays dimmed"
        )
    }

    @Test("filtering to a single result arms it")
    func soleMatchIsArmed() {
        let model = model()
        model.searchText = "SQLite"
        #expect(model.orderedTypes == [.sqlite])
        #expect(model.highlightedType == .sqlite)
    }

    @Test("a query matching nothing clears the highlight")
    func noMatchClearsTheHighlight() {
        let model = model()
        model.searchText = "SQLite"
        #expect(model.highlightedType == .sqlite)

        model.searchText = "nothing matches this"
        #expect(model.orderedTypes.isEmpty)
        #expect(model.highlightedType == nil)
    }

    @Test("a highlight the query still shows survives further typing")
    func visibleHighlightSurvives() {
        let model = model()
        model.highlightedType = .postgresql
        model.searchText = "postgres"
        #expect(model.highlightedType == .postgresql)
    }

    @Test("clearing the query keeps the driver the user had narrowed to")
    func clearingKeepsAVisibleHighlight() {
        let model = model()
        model.searchText = "SQLite"
        #expect(model.highlightedType == .sqlite)

        model.searchText = ""
        #expect(
            model.highlightedType == .sqlite,
            "Every driver is visible again and this one still is, so the choice stands"
        )
    }

    @Test("a fresh model with no query arms nothing")
    func emptyQueryOnOpenArmsNothing() {
        let model = model()
        model.searchText = ""
        #expect(model.highlightedType == nil, "Opening the chooser must not pre-arm a driver")
    }

    @Test("arrowing walks the rows in the order the list draws them")
    func arrowingFollowsDisplayOrder() {
        let model = model()
        let rows = model.orderedTypes
        #expect(rows.count > 2)

        model.moveHighlight(by: 1)
        #expect(model.highlightedType == rows.first)

        model.moveHighlight(by: 1)
        #expect(model.highlightedType == rows[1])

        model.moveHighlight(by: -1)
        #expect(model.highlightedType == rows.first)
    }

    @Test("arrowing stops at the ends rather than wrapping")
    func arrowingClampsAtTheEnds() {
        let model = model()
        let rows = model.orderedTypes

        model.highlightedType = rows.first
        model.moveHighlight(by: -1)
        #expect(model.highlightedType == rows.first)

        model.highlightedType = rows.last
        model.moveHighlight(by: 1)
        #expect(model.highlightedType == rows.last)
    }

    @Test("arrowing up from nothing arms the last row")
    func arrowingUpFromNothingArmsTheLast() {
        let model = model()
        model.moveHighlight(by: -1)
        #expect(model.highlightedType == model.orderedTypes.last)
    }

    @Test("preselecting an initial type is left alone by the filter it still matches")
    func preselectSurvivesAMatchingFilter() {
        let model = model()
        model.preselect(.mariadb)
        model.searchText = "Maria"
        #expect(model.highlightedType == .mariadb)
    }
}
