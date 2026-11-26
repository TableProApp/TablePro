//
//  TeamLibraryFieldConflictSheetTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct TeamLibraryFieldConflictSheetTests {
    private typealias Presentation = TeamLibraryFieldConflictPresentation

    @Test("Only the fields both sides changed show, in the editor's order, with the SQL as code")
    func queryConflictShowsTheContestedFields() {
        let presentation = Presentation(
            conflict: TeamConflictFixture.conflict(
                fields: ["keyword", "name", "query"],
                mine: ["name": "Orders", "keyword": "ord", "query": "select mine", "sort_order": 1],
                theirs: ["name": "Open Orders", "keyword": "", "query": "select theirs", "sort_order": 1]
            ),
            teamName: "Acme"
        )

        #expect(presentation.shape == .bothChanged)
        #expect(presentation.title.contains("Orders"))
        #expect(presentation.message.contains("Acme"))
        #expect(presentation.rows == [
            Presentation.Row(field: "name", label: String(localized: "Name"), mine: .text("Orders"), theirs: .text("Open Orders")),
            Presentation.Row(field: "keyword", label: String(localized: "Keyword"), mine: .text("ord"), theirs: .empty),
            Presentation.Row(field: "query", label: "SQL", mine: .code("select mine"), theirs: .code("select theirs"))
        ])
    }

    @Test("Numbers, switches, nested settings, missing values and a field a newer build wrote each read plainly")
    func connectionValuesReadPlainly() {
        let presentation = Presentation(
            conflict: TeamConflictFixture.conflict(
                "c1",
                kind: "library_connection",
                fields: ["database", "localOnly", "port", "sshConfig", "zoneHint"],
                mine: [
                    "name": "Prod", "port": 5_432, "database": "", "localOnly": true,
                    "sshConfig": ["port": 22, "host": "bastion"], "zoneHint": "eu"
                ],
                theirs: ["name": "Prod", "port": 5_433, "database": "prod", "sshConfig": NSNull()]
            ),
            teamName: "Acme"
        )

        let fields = presentation.rows.map { $0.field }
        let labels = presentation.rows.map { $0.label }
        let mine = presentation.rows.map { $0.mine }
        let theirs = presentation.rows.map { $0.theirs }
        #expect(fields == ["port", "database", "sshConfig", "localOnly", "zoneHint"])
        #expect(labels == [
            String(localized: "Port"), String(localized: "Database"), String(localized: "SSH"),
            String(localized: "Local Only"), "zoneHint"
        ])
        #expect(mine == [
            .text("5432"), .empty, .code(#"{"host":"bastion","port":22}"#), .text(String(localized: "Yes")), .text("eu")
        ])
        #expect(theirs == [.text("5433"), .text("prod"), .notSet, .notSet, .notSet])
    }

    @Test("Against a deletion only the side that kept the item has values, and the wording says who deleted it")
    func deletionsShowTheKeptSide() {
        let youDeleted = Presentation(
            conflict: TeamConflictFixture.conflict(fields: ["query"], mine: nil, theirs: ["name": "Orders", "query": "select 2"]),
            teamName: "Acme"
        )
        #expect(youDeleted.shape == .youDeleted)
        #expect(youDeleted.title.contains("Orders"), "The name comes from the team's copy when this Mac deleted its own")
        #expect(youDeleted.rows == [Presentation.Row(field: "query", label: "SQL", mine: nil, theirs: .code("select 2"))])

        let teamDeleted = Presentation(
            conflict: TeamConflictFixture.conflict(fields: ["query"], mine: ["name": "Orders", "query": "select 1"], theirs: nil),
            teamName: "Acme"
        )
        #expect(teamDeleted.shape == .teamDeleted)
        #expect(teamDeleted.rows == [Presentation.Row(field: "query", label: "SQL", mine: .code("select 1"), theirs: nil)])
        #expect(teamDeleted.title != youDeleted.title)
        #expect(teamDeleted.message != youDeleted.message)
    }

    @Test("An item with no name is named by its id, and an unnamed team as your team")
    func fallbacks() {
        let presentation = Presentation(
            conflict: TeamConflictFixture.conflict("f1", kind: "library_folder", fields: ["parent_client_id"], mine: ["parent_client_id": "a"], theirs: ["parent_client_id": "b"]),
            teamName: nil
        )

        let labels = presentation.rows.map { $0.label }
        #expect(presentation.title.contains("f1"))
        #expect(presentation.message.contains(String(localized: "your team")))
        #expect(labels == [String(localized: "Folder")])
    }

    @Test("Each side's value, Keep Mine, Keep Theirs and Decide Later are reachable through accessibility")
    func contentThroughAccessibility() async throws {
        var kept: [ConflictChoiceTag] = []
        var later = 0
        let view = TeamLibraryFieldConflictContent(
            presentation: Presentation(conflict: TeamConflictFixture.conflict(), teamName: "Acme"),
            remaining: 2,
            isResolving: false,
            failure: "TablePro couldn't save your choice. Try again.",
            decideLater: { later += 1 },
            keep: { kept.append($0) }
        )
        let window = try await HostedAccessibility.host(view, showing: "team-library-conflict-keep-mine")
        defer { window.orderOut(nil) }

        let mineValue = try #require(HostedAccessibility.element("team-library-conflict-mine-query", in: window))
        let theirsValue = try #require(HostedAccessibility.element("team-library-conflict-theirs-query", in: window))
        #expect(HostedAccessibility.label(of: mineValue) == String(localized: "Your Version"))
        #expect(HostedAccessibility.value(of: mineValue) == "select mine")
        #expect(HostedAccessibility.value(of: theirsValue) == "select theirs")
        #expect(HostedAccessibility.element("team-library-conflict-failure", in: window) != nil)

        let mine = try #require(HostedAccessibility.element("team-library-conflict-keep-mine", in: window))
        let theirs = try #require(HostedAccessibility.element("team-library-conflict-keep-theirs", in: window))
        let decideLater = try #require(HostedAccessibility.element("team-library-conflict-later", in: window))
        #expect(HostedAccessibility.label(of: mine) == String(localized: "Keep Mine"))
        #expect(HostedAccessibility.label(of: theirs) == String(localized: "Keep Theirs"))

        HostedAccessibility.press(mine)
        try await waitUntil { kept == [.keepMine] }
        HostedAccessibility.press(theirs)
        try await waitUntil { kept == [.keepMine, .keepTheirs] }
        HostedAccessibility.press(decideLater)
        try await waitUntil { later == 1 }
    }

    @Test("An item the team deleted shows only this Mac's column")
    func deletionShowsOneColumn() async throws {
        let view = TeamLibraryFieldConflictContent(
            presentation: Presentation(
                conflict: TeamConflictFixture.conflict(fields: ["query"], mine: ["name": "Orders", "query": "select 1"], theirs: nil),
                teamName: "Acme"
            ),
            remaining: 1,
            isResolving: false,
            failure: nil,
            decideLater: {},
            keep: { _ in }
        )
        let window = try await HostedAccessibility.host(view, showing: "team-library-conflict-mine-query")
        defer { window.orderOut(nil) }

        #expect(HostedAccessibility.element("team-library-conflict-theirs-query", in: window) == nil)
        #expect(HostedAccessibility.element("team-library-conflict-failure", in: window) == nil)
    }
}
