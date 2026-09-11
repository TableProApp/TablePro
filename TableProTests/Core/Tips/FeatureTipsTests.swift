//
//  FeatureTipsTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("FeatureTipsPlan")
struct FeatureTipsPlanTests {
    private let support = URL(fileURLWithPath: "/tmp/tablepro-support", isDirectory: true)

    @Test("The unit test host never configures tips")
    func unitTestHost() {
        #expect(FeatureTipsPlan.resolve(
            isUnitTestHost: true,
            isIsolated: false,
            supportDirectory: support,
            requestedTipIds: nil
        ) == nil)
    }

    @Test("A shipped launch shows every tip and keeps the store under the support directory")
    func production() throws {
        let plan = try #require(FeatureTipsPlan.resolve(
            isUnitTestHost: false,
            isIsolated: false,
            supportDirectory: support,
            requestedTipIds: "open-quickly"
        ))

        #expect(plan.visibility == .normal)
        #expect(plan.datastoreDirectory == support.appendingPathComponent("Tips", isDirectory: true))
        #expect(plan.allows(OpenQuicklyTip.tipId))
    }

    @Test("A UI test sandbox hides every tip unless the test names one")
    func sandboxHidesTips() throws {
        let plan = try #require(FeatureTipsPlan.resolve(
            isUnitTestHost: false,
            isIsolated: true,
            supportDirectory: support,
            requestedTipIds: nil
        ))

        #expect(plan.visibility == .hideAll)
        #expect(!plan.allows(OpenQuicklyTip.tipId))
    }

    @Test("A UI test sandbox shows only the tips the test names")
    func sandboxShowsNamedTips() throws {
        let plan = try #require(FeatureTipsPlan.resolve(
            isUnitTestHost: false,
            isIsolated: true,
            supportDirectory: support,
            requestedTipIds: " open-quickly , find-past-queries "
        ))

        #expect(plan.visibility == .showOnly([OpenQuicklyTip.tipId, FindPastQueriesTip.tipId]))
        #expect(plan.allows(FindPastQueriesTip.tipId))
        #expect(!plan.allows(KeepTableOpenTip.tipId))
    }
}

@Suite("FeatureTipCatalog")
struct FeatureTipCatalogTests {
    @Test("Tip ids are stored keys, so they never change")
    func pinnedIds() {
        #expect(FeatureTipCatalog.ids == ["keep-table-open", "open-quickly", "find-past-queries"])
        #expect(Set(FeatureTipCatalog.ids).count == FeatureTipCatalog.ids.count)
    }

    @Test("Named ids map to their tip types")
    func typesForIds() {
        let types = FeatureTipCatalog.types(for: [OpenQuicklyTip.tipId])

        #expect(types.count == 1)
        #expect(types.first == OpenQuicklyTip.self)
    }
}

@Suite("FeatureTipCopy")
struct FeatureTipCopyTests {
    @Test("A bound shortcut is named in the message")
    func withShortcut() {
        #expect(FeatureTipCopy.openQuicklyMessage(shortcut: "⇧⌘O").contains("⇧⌘O"))
        #expect(FeatureTipCopy.findPastQueriesMessage(shortcut: "⌘Y").contains("⌘Y"))
    }

    @Test("A cleared shortcut points at the menu item instead")
    func withoutShortcut() {
        #expect(FeatureTipCopy.openQuicklyMessage(shortcut: nil).contains("Open Quickly…"))
        #expect(FeatureTipCopy.findPastQueriesMessage(shortcut: "").contains("Show Query History"))
    }
}
