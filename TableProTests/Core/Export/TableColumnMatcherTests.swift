//
//  TableColumnMatcherTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct TableColumnMatcherTests {
    @Test("Columns are matched by name, and the rest are reported on both sides")
    func matchesByName() {
        let match = TableColumnMatcher.match(
            source: ["id", "name", "legacy"], destination: ["id", "name", "created_at"])

        #expect(match.mapping == ["id": "id", "name": "name"])
        #expect(match.unmatchedSource == ["legacy"])
        #expect(match.unmatchedDestination == ["created_at"])
        #expect(match.contestedDestinations.isEmpty)
    }

    @Test("A column spelled with another case still matches")
    func matchesIgnoringCase() {
        let match = TableColumnMatcher.match(source: ["ID", "Email"], destination: ["id", "email"])

        #expect(match.mapping == ["ID": "id", "Email": "email"])
        #expect(match.unmatchedSource.isEmpty)
    }

    /// Both used to land on `name`, and the INSERT named it twice.
    @Test("The exact spelling claims a destination column before a twin that differs only by case")
    func exactSpellingWinsTheColumn() {
        let match = TableColumnMatcher.match(source: ["Name", "name"], destination: ["id", "name"])

        #expect(match.mapping == ["name": "name"])
        #expect(match.unmatchedSource == ["Name"])
        #expect(match.contestedDestinations.isEmpty)
    }

    @Test("Of two twins that both differ by case from the destination, only the first is matched")
    func firstTwinWinsTheColumn() {
        let match = TableColumnMatcher.match(source: ["NAME", "Name"], destination: ["name"])

        #expect(match.mapping == ["NAME": "name"])
        #expect(match.unmatchedSource == ["Name"])
    }

    @Test("Twins on both sides each reach their own column")
    func twinsReachTheirOwnColumns() {
        let match = TableColumnMatcher.match(source: ["Name", "name"], destination: ["name", "Name"])

        #expect(match.mapping == ["Name": "Name", "name": "name"])
        #expect(match.unmatchedDestination.isEmpty)
    }

    @Test("A destination twin left over is matched ignoring case once the exact spelling is taken")
    func leftoverTwinMatchesIgnoringCase() {
        let match = TableColumnMatcher.match(source: ["NAME", "Name"], destination: ["Name", "name"])

        #expect(match.mapping == ["Name": "Name", "NAME": "name"])
    }

    @Test("An override onto a column another source column holds is kept and reported as contested")
    func overrideOntoAHeldColumnIsContested() {
        let match = TableColumnMatcher.match(
            source: ["first_name", "last_name"],
            destination: ["first_name", "last_name"],
            overrides: ["last_name": "first_name"]
        )

        #expect(match.mapping == ["first_name": "first_name", "last_name": "first_name"])
        #expect(match.contestedDestinations == ["first_name"])
        #expect(match.unmatchedDestination == ["last_name"])
    }

    @Test("Skipping one of the two source columns clears the contest")
    func skippingOneClearsTheContest() {
        let match = TableColumnMatcher.match(
            source: ["first_name", "last_name"],
            destination: ["first_name", "last_name"],
            overrides: ["last_name": "first_name", "first_name": nil]
        )

        #expect(match.mapping == ["last_name": "first_name"])
        #expect(match.contestedDestinations.isEmpty)
        #expect(match.unmatchedSource == ["first_name"])
    }

    @Test("Repointing a case twin onto the column its twin holds is contested")
    func repointedTwinIsContested() {
        let match = TableColumnMatcher.match(
            source: ["Name", "name"],
            destination: ["name"],
            overrides: ["Name": "name"]
        )

        #expect(match.contestedDestinations == ["name"])
    }

    @Test("No overrides gives the automatic match")
    func noOverridesIsTheAutomaticMatch() {
        let source = ["id", "Name", "name"]
        let destination = ["id", "name"]

        #expect(
            TableColumnMatcher.match(source: source, destination: destination, overrides: [:])
                == TableColumnMatcher.match(source: source, destination: destination)
        )
    }

    @Test("Only destination columns named more than once are contested, in name order")
    func contestedDestinationsAreSorted() {
        let contested = TableColumnMatcher.contestedDestinations(
            in: ["a": "z", "b": "z", "c": "y", "d": "x", "e": "x", "f": "x"])

        #expect(contested == ["x", "z"])
    }
}
