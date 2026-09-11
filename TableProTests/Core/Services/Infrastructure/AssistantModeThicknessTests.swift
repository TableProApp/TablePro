//
//  AssistantModeThicknessTests.swift
//  TableProTests
//
//  Assistant mode has no TabType of its own, so it declares the detail pane's minimum itself.
//  Browse mode has to come out of that change byte for byte, or a window that was sized for a
//  Users & Roles tab loses the width that tab needs.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Assistant mode detail thickness")
@MainActor
struct AssistantModeThicknessTests {
    private static let everyTabType: [TabType] = [
        .query, .table, .createTable, .erDiagram, .serverDashboard, .insights, .usersRoles,
    ]

    @Test("Browse mode answers exactly what the tab-only resolver answers, for every tab type")
    func browseModeMatchesTabResolver() {
        for tabType in Self.everyTabType {
            #expect(
                MainSplitViewController.resolveDetailMinimumThickness(mode: .browse, tabType: tabType)
                    == MainSplitViewController.resolveDetailMinimumThickness(for: tabType),
                "browse mode changed for \(tabType)"
            )
        }
    }

    @Test("Browse mode with no tab is the default minimum")
    func browseModeWithoutTabIsDefault() {
        #expect(
            MainSplitViewController.resolveDetailMinimumThickness(mode: .browse, tabType: nil)
                == MainSplitViewController.defaultDetailMinThickness
        )
    }

    /// The connection's tabs are still open in assistant mode; they are just not what the detail
    /// pane is showing, so their width is not what it has to fit. A Users & Roles tab left open
    /// must not hold the assistant surface at that tab's minimum.
    @Test("Assistant mode reports its own minimum whatever tab is selected underneath")
    func assistantModeIgnoresTheSelectedTab() {
        for tabType in Self.everyTabType {
            #expect(
                MainSplitViewController.resolveDetailMinimumThickness(mode: .assistant, tabType: tabType)
                    == MainSplitViewController.assistantDetailMinThickness,
                "assistant mode followed the tab for \(tabType)"
            )
        }
        #expect(
            MainSplitViewController.resolveDetailMinimumThickness(mode: .assistant, tabType: nil)
                == MainSplitViewController.assistantDetailMinThickness
        )
    }

    /// The artifact pane opens by default, so the assistant surface has to fit inside a window that
    /// also carries a sidebar and an inspector at their own minimums. Costing it more than a browse
    /// window would have made entering the mode resize the user's window.
    @Test("Assistant mode never costs more width than browse mode")
    func assistantModeIsNotWiderThanBrowse() {
        #expect(
            MainSplitViewController.assistantDetailMinThickness
                <= MainSplitViewController.defaultDetailMinThickness
        )
    }
}
