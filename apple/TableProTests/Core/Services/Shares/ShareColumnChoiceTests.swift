//
//  ShareColumnChoiceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ShareColumnChoiceTests {
    @Test("A rule-masked column starts masked with the rule's style, refuses Keep and offers only stricter styles")
    func ruleMaskedColumn() throws {
        let choice = ShareColumnChoice(index: 0, name: "phone", ruleStyle: .lastFour, detection: nil)
        #expect(choice.action == .mask)
        #expect(choice.style == .lastFour)
        #expect(!choice.allowsKeep)
        #expect(choice.allowedStyles == [.full, .lastFour, .null])
        #expect(choice.choosing(.keep) == nil)
        #expect(choice.choosing(style: .email) == nil)
        #expect(try #require(choice.choosing(.remove)).sharedColumn == nil)
        #expect(ShareColumnChoice(index: 0, name: "x", ruleStyle: .null, detection: nil).allowedStyles == [.null])
        #expect(ShareColumnChoice(index: 0, name: "x", ruleStyle: .full, detection: nil).allowedStyles == [.full, .null])
    }

    @Test("A rule's own style is already on the values, so only a stricter one is applied again")
    func ruleStyleIsNotAppliedTwice() throws {
        let choice = ShareColumnChoice(index: 3, name: "ip", ruleStyle: .hash, detection: nil)
        #expect(choice.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 3, applying: nil, masked: .hash))
        let stricter = try #require(choice.choosing(style: .full))
        #expect(stricter.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 3, applying: .full, masked: .full))
    }

    @Test("A detected column starts masked with the suggested style and may be kept")
    func detectedColumn() throws {
        let choice = ShareColumnChoice(index: 1, name: "contact", ruleStyle: nil, detection: .values(.email))
        #expect(choice.action == .mask)
        #expect(choice.style == .email)
        #expect(choice.allowedStyles == MaskingStyle.allCases)
        #expect(choice.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 1, applying: .email, masked: .email))
        let kept = try #require(choice.choosing(.keep))
        #expect(kept.sharedColumn == ShareSnapshotBuilder.SharedColumn(source: 1, applying: nil, masked: nil))
        #expect(kept.maskedStyle == nil)
    }

    @Test("Any other column starts kept")
    func plainColumn() {
        let choice = ShareColumnChoice(index: 0, name: "id", ruleStyle: nil, detection: nil)
        #expect(choice.action == .keep)
        #expect(choice.allowsKeep)
    }

    @Test("A column masked only because nothing traced it says so and cannot be kept")
    func untracedColumn() throws {
        let source = ShareResultSource(
            columns: ["id", "total"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: nil)],
            rows: [[.text("1"), .text("••••")]],
            totalRowCount: 1,
            sql: "",
            masks: ColumnMasks(styles: [1: .full]),
            untracedColumns: [1]
        )
        let choices = try #require(ShareColumnChoice.defaults(for: source, windows: [10]))
        #expect(choices.map(\.isUntraced) == [false, true])
        #expect(!choices[1].allowsKeep)
        #expect(choices[1].allowedStyles == [.full, .null])
    }

    @Test("Choices carry over by name, held to what each column now allows")
    func carryOver() throws {
        let earlier = [
            try #require(ShareColumnChoice(index: 0, name: "id", ruleStyle: nil, detection: nil).choosing(.remove)),
            try #require(ShareColumnChoice(index: 1, name: "phone", ruleStyle: nil, detection: nil).choosing(style: .email)?.choosing(.mask)),
            ShareColumnChoice(index: 2, name: "gone", ruleStyle: nil, detection: nil)
        ]
        let defaults = [
            ShareColumnChoice(index: 0, name: "phone", ruleStyle: .lastFour, detection: nil),
            ShareColumnChoice(index: 1, name: "id", ruleStyle: nil, detection: nil),
            ShareColumnChoice(index: 2, name: "new", ruleStyle: nil, detection: .values(.email))
        ]
        let carried = ShareColumnChoice.carryingOver(earlier, onto: defaults)
        #expect(carried.map(\.action) == [.mask, .remove, .mask])
        #expect(carried.map(\.style) == [.lastFour, .full, .email])
        #expect(carried.map(\.index) == [0, 1, 2])
    }

    private static func bodyAndNotes(_ rows: [[PluginCellValue]]) -> ShareResultSource {
        ShareResultSource(
            columns: ["body", "notes"],
            columnTypes: [.text(rawType: "text"), .text(rawType: "text")],
            rows: rows,
            totalRowCount: rows.count,
            sql: ""
        )
    }

    private static func snapshotRows(_ outcome: ShareSnapshotOutcome?) -> [[ShareCell]]? {
        guard case .snapshot(let snapshot) = outcome else { return nil }
        return snapshot.rows
    }

    @Test("A card past the rows the body budget sends still flags the column, and the snapshot may go to max_rows")
    func detectionReadsPastTheBudget() throws {
        let wide = String(repeating: "y", count: 200_000)
        var rows: [[PluginCellValue]] = Array(repeating: [.text(wide), .text("x")], count: 40)
        rows[39][1] = .text("4111111111111111")
        let prepared = try #require(ShareColumnChoice.prepare(Self.bodyAndNotes(rows), maxRows: 1_000, keeping: []))
        let sent = try #require(Self.snapshotRows(prepared.snapshot))

        #expect(sent.count < 40)
        #expect(prepared.rowCap == 1_000)
        #expect(prepared.columns.map(\.action) == [.keep, .mask])
        #expect(prepared.columns[1].detection == .values(.card))
    }

    @Test("A 300 KiB cell in the first row refuses the whole snapshot, and the notes' emails are still flagged")
    func refusedSnapshotStillDetects() throws {
        var rows: [[PluginCellValue]] = (0..<10).map { [.text("short"), .text("user\($0)@example.com")] }
        rows[0][0] = .text(String(repeating: "y", count: 300 * 1_024))
        let source = Self.bodyAndNotes(rows)
        #expect(ShareSnapshotBuilder.build(source, maxRows: 1_000) == .tooLarge)

        let prepared = try #require(ShareColumnChoice.prepare(source, maxRows: 1_000, keeping: []))
        #expect(prepared.columns.map(\.action) == [.keep, .mask])
        #expect(prepared.columns[1].detection == .values(.email))

        let notesOnly = try #require(prepared.columns[0].choosing(.remove))
        let shared = [notesOnly, prepared.columns[1]].compactMap(\.sharedColumn)
        let sent = try #require(Self.snapshotRows(ShareSnapshotBuilder.build(source, maxRows: prepared.rowCap, columns: shared)))
        #expect(sent.count == 10)
        #expect(sent.last == [.string("u•••@example.com")])
    }

    @Test("Emails only in the rows that fit once a wide column is removed are flagged, and those rows go masked")
    func emailsPastTheBudgetAreFlagged() throws {
        let wide = String(repeating: "y", count: 250_000)
        let rows: [[PluginCellValue]] = (0..<40).map { index in
            [.text(wide), .text(index < 20 ? "no address here" : "user\(index)@example.com")]
        }
        let source = Self.bodyAndNotes(rows)
        let keptWhole = try #require(Self.snapshotRows(ShareSnapshotBuilder.build(source, maxRows: 1_000)))
        #expect(keptWhole.count <= 20)

        let prepared = try #require(ShareColumnChoice.prepare(source, maxRows: 1_000, keeping: []))
        #expect(prepared.columns.map(\.action) == [.keep, .mask])
        #expect(prepared.columns[1].detection == .values(.email))

        let notesOnly = try #require(prepared.columns[0].choosing(.remove))
        let shared = [notesOnly, prepared.columns[1]].compactMap(\.sharedColumn)
        let sent = try #require(Self.snapshotRows(ShareSnapshotBuilder.build(source, maxRows: prepared.rowCap, columns: shared)))
        #expect(sent.count == 40)
        #expect(sent.last == [.string("u•••@example.com")])
    }

    @Test("Defaults come from the source's rule masks and the detectors")
    func defaults() throws {
        let source = ShareResultSource(
            columns: ["id", "email", "password"],
            columnTypes: [.integer(rawType: "int8"), .text(rawType: "text"), .text(rawType: "text")],
            rows: [[.text("1"), .text("j•••@x.io"), .text("hunter2")]],
            totalRowCount: 1,
            sql: "",
            masks: ColumnMasks(styles: [1: .email])
        )
        let choices = try #require(ShareColumnChoice.defaults(for: source, windows: [10]))
        #expect(choices.map(\.action) == [.keep, .mask, .mask])
        #expect(choices.map(\.style) == [.full, .email, .full])
        #expect(choices.map(\.ruleStyle) == [nil, .email, nil])
        #expect(choices.map(\.detection) == [nil, nil, .name(.secret)])
    }
}
