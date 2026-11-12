//
//  QueryTabRevertMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct QueryTabRevertMenuTests {
    private static let revert = #selector(MainSplitViewController.revertToQueryTabVersion(_:))
    private static let browse = #selector(MainSplitViewController.browseQueryTabVersions(_:))

    private func fileMenu() throws -> NSMenu {
        let bar = MainMenuBuilder.build(keyboard: KeyboardSettings()).bar
        return try #require(bar.items.first { $0.title == String(localized: "File") }?.submenu)
    }

    private func summary(_ id: Int64, _ reason: QueryTabVersionReason) -> QueryTabVersionSummary {
        QueryTabVersionSummary(id: id, reason: reason, savedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(id)))
    }

    @Test("Revert To follows Save As in File, fills when it opens and carries no shortcut")
    func revertToFollowsSaveAs() throws {
        let file = try fileMenu()
        let saveAs = try #require(file.items.firstIndex {
            $0.action == #selector(MainSplitViewController.saveDocumentAs(_:))
        })
        let revertTo = file.items[saveAs + 1]

        #expect(revertTo.title == String(localized: "Revert To"))
        #expect(revertTo.keyEquivalent.isEmpty)
        #expect(revertTo.submenu?.delegate is QueryTabRevertMenuDelegate)
        #expect(revertTo.submenu?.items.isEmpty == true)
    }

    @Test("The list is the tab's versions, then Browse All Versions…")
    func listsVersionsThenBrowse() throws {
        let menu = NSMenu()
        let tabId = UUID()

        QueryTabRevertMenuDelegate.fill(menu, tabId: tabId, summaries: [summary(2, .run), summary(1, .idle)])

        #expect(menu.items.count == 4)
        #expect(menu.items[0].action == Self.revert)
        #expect(menu.items[0].target == nil)
        #expect(menu.items[0].representedObject as? QueryTabRevertChoice == QueryTabRevertChoice(tabId: tabId, versionId: 2))
        #expect(menu.items[1].representedObject as? QueryTabRevertChoice == QueryTabRevertChoice(tabId: tabId, versionId: 1))
        #expect(menu.items[0].title.contains(String(localized: "Run")))
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[3].title == String(localized: "Browse All Versions…"))
        #expect(menu.items[3].action == Self.browse)
        #expect(menu.items[3].target == nil)
    }

    @Test("With no versions the list says so and still offers Browse All Versions…")
    func emptyListShowsThePlaceholder() {
        let menu = NSMenu()
        menu.addItem(withTitle: "stale", action: nil, keyEquivalent: "")

        QueryTabRevertMenuDelegate.fill(menu, tabId: UUID(), summaries: [])

        #expect(menu.items.map { $0.title } == [
            String(localized: "None Available"), "", String(localized: "Browse All Versions…"),
        ])
        #expect(menu.items[0].isEnabled == false)
    }

    @Test("Revert To and Browse All Versions need a query tab, and no connection")
    func commandsNeedAQueryTab() {
        for selector in [Self.revert, Self.browse] {
            var context = MenuValidationContext()
            #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == false)

            context.isQueryTab = true
            #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == true)

            context.isAgentMode = true
            #expect(MainSplitViewController.resolvedEnablement(selector, context: context) == false)
        }
    }

    @Test("The window answers both commands")
    func windowImplementsBoth() {
        #expect(MainSplitViewController.instancesRespond(to: Self.revert))
        #expect(MainSplitViewController.instancesRespond(to: Self.browse))
    }
}
