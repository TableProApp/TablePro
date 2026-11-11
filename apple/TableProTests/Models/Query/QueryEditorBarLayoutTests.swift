//
//  QueryEditorBarLayoutTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QueryEditorBarLayoutTests {
    private static func rows(
        twoRows: Bool,
        showsQueryBuilder: Bool = true,
        showsAI: Bool = true,
        showsVimMode: Bool = false
    ) -> [QueryEditorBarRow] {
        QueryEditorBarLayout.rows(
            twoRows: twoRows,
            showsQueryBuilder: showsQueryBuilder,
            showsAI: showsAI,
            showsVimMode: showsVimMode
        )
    }

    @Test("Off, the bar is the single row it always was")
    func singleRowIsTodaysBar() {
        #expect(Self.rows(twoRows: false) == [
            QueryEditorBarRow(leading: [.database], trailing: [.editingCommands, .ai, .explain, .run]),
        ])
    }

    @Test("On, the editing tools take the first row and the target and run controls the second")
    func twoRowsSplitByWhatEachControlActsOn() {
        #expect(Self.rows(twoRows: true) == [
            QueryEditorBarRow(leading: [.save, .separator, .queryBuilder, .format, .snippets, .ai], trailing: []),
            QueryEditorBarRow(leading: [.connection, .database], trailing: [.explain, .run]),
        ])
    }

    @Test("The commands only the two-row bar adds never reach the single row")
    func singleRowHoldsNoTwoRowControl() {
        let controls = Self.rows(twoRows: false).flatMap { $0.leading + $0.trailing }
        for added in [QueryEditorBarControl.save, .separator, .queryBuilder, .format, .snippets, .connection] {
            #expect(!controls.contains(added))
        }
    }

    @Test("Each control appears once in either layout")
    func noControlTwice() {
        for twoRows in [false, true] {
            let controls = Self.rows(twoRows: twoRows, showsVimMode: true).flatMap { $0.leading + $0.trailing }
            #expect(controls.count == Set(controls).count)
        }
    }

    @Test("Query Builder is left out where the engine cannot build a join")
    func queryBuilderHiddenWhereUnsupported() {
        let rows = Self.rows(twoRows: true, showsQueryBuilder: false)
        #expect(rows.first?.leading == [.save, .separator, .format, .snippets, .ai])
        #expect(!rows.flatMap { $0.leading + $0.trailing }.contains(.queryBuilder))
    }

    @Test("The AI control and the Vim indicator follow their own conditions in both layouts")
    func optionalControls() {
        let single = Self.rows(twoRows: false, showsAI: false, showsVimMode: true)
        #expect(single == [QueryEditorBarRow(leading: [.database, .vimMode], trailing: [.editingCommands, .explain, .run])])

        let double = Self.rows(twoRows: true, showsAI: false, showsVimMode: true)
        #expect(double.first?.leading == [.save, .separator, .queryBuilder, .format, .snippets])
        #expect(double.last == QueryEditorBarRow(leading: [.connection, .database, .vimMode], trailing: [.explain, .run]))
    }

    // MARK: - Tool hues

    private static let tools: [QueryEditorBarControl] = [.save, .queryBuilder, .format, .snippets, .ai]

    @Test("In the colorful style each first-row tool wears a hue of its own")
    func colorfulToolsEachHaveAHue() {
        let tints = Self.tools.compactMap { QueryEditorBarToolTint.tint(for: $0, style: .colorful) }
        #expect(tints.count == Self.tools.count)
        #expect(Set(tints).count == tints.count)
    }

    @Test("The standard style and the second row stay monochrome")
    func standardStyleAndSecondRowStayPlain() {
        let every: [QueryEditorBarControl] = Self.tools + [
            .database, .vimMode, .editingCommands, .explain, .run, .separator, .connection,
        ]
        for control in every {
            #expect(QueryEditorBarToolTint.tint(for: control, style: .standard) == nil)
        }
        for control in [QueryEditorBarControl.database, .vimMode, .editingCommands, .explain, .run, .separator, .connection] {
            #expect(QueryEditorBarToolTint.tint(for: control, style: .colorful) == nil)
        }
    }
}
