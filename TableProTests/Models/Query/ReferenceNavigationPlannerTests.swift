import Foundation
import Testing

@testable import TablePro

struct ReferenceNavigationPlannerTests {
    private func context(
        intent: ReferenceOpenIntent = .follow,
        showsTarget: Bool = false,
        acceptsRefilter: Bool = true,
        anotherTab: Bool = false
    ) -> ReferenceNavigationContext {
        ReferenceNavigationContext(
            intent: intent,
            selectedTabShowsTarget: showsTarget,
            selectedTabAcceptsRefilter: acceptsRefilter,
            anotherTabShowsReference: anotherTab
        )
    }

    @Test("A table tab the reader is in keeps its place, and the reference gets its own tab")
    func followFromATableTabOpensItsOwnTab() {
        #expect(ReferenceNavigationPlanner.plan(for: context()) == .openNewTab)
    }

    @Test("The tab already on the referenced table is re-filtered rather than duplicated")
    func followOnTheTargetTableRefiltersInPlace() {
        #expect(ReferenceNavigationPlanner.plan(for: context(showsTarget: true)) == .refilterSelectedTab)
    }

    /// The discard alert clears staged cell edits and nothing else, so a re-query under a staged
    /// structure edit would promise something the path cannot keep. Back and Forward stand down on
    /// the same tab for the same reason.
    @Test("A staged structure edit sends the reference to its own tab instead of re-filtering")
    func stagedStructureEditsRefuseTheRefilter() {
        let plan = ReferenceNavigationPlanner.plan(
            for: context(showsTarget: true, acceptsRefilter: false)
        )
        #expect(plan == .openNewTab)
    }

    @Test("A tab already showing this reference is brought forward rather than built again")
    func followRevealsTheTabAlreadyShowingTheReference() {
        #expect(ReferenceNavigationPlanner.plan(for: context(anotherTab: true)) == .revealExistingTab)
    }

    @Test("Re-filtering the tab the reader is on wins over revealing another")
    func refilterBeatsReveal() {
        let plan = ReferenceNavigationPlanner.plan(for: context(showsTarget: true, anotherTab: true))
        #expect(plan == .refilterSelectedTab)
    }

    @Test("Command-click always takes a tab of its own")
    func newTabIgnoresEveryOtherOutcome() {
        for showsTarget in [true, false] {
            for anotherTab in [true, false] {
                let plan = ReferenceNavigationPlanner.plan(
                    for: context(intent: .newTab, showsTarget: showsTarget, anotherTab: anotherTab)
                )
                #expect(plan == .openNewTab)
            }
        }
    }
}
