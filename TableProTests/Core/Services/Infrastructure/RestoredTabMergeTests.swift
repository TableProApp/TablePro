//
//  RestoredTabMergeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct RestoredTabMergeTests {
    private func queryTab(_ title: String, file: String? = nil) -> QueryTab {
        var tab = QueryTab(title: title, query: "SELECT '\(title)'", tabType: .query)
        tab.content.sourceFileURL = file.map { URL(fileURLWithPath: "/tmp/\($0)") }
        return tab
    }

    private func merge(
        restored: [QueryTab],
        restoredSelection: UUID? = nil,
        present: [QueryTab] = [],
        presentSelection: UUID? = nil,
        heldElsewhere: Set<UUID> = []
    ) -> RestoredTabMerge {
        RestoredTabMerge.merge(
            restored: restored,
            restoredSelection: restoredSelection,
            present: present,
            presentSelection: presentSelection,
            heldElsewhere: heldElsewhere
        )
    }

    /// The regression this guards: a tab adopted before the view first appeared was replaced by the
    /// saved set and lost.
    @Test("A tab already in the list survives the restore, after the saved tabs")
    func presentTabSurvives() {
        let saved = [queryTab("Saved A"), queryTab("Saved B")]
        let moved = queryTab("Moved")

        let result = merge(restored: saved, restoredSelection: saved[1].id, present: [moved], presentSelection: moved.id)

        #expect(result.tabs.map(\.id) == saved.map(\.id) + [moved.id])
        #expect(result.restoredTabIds == Set(saved.map(\.id)))
    }

    @Test("A present tab keeps the selection")
    func presentSelectionWins() {
        let saved = [queryTab("Saved A"), queryTab("Saved B")]
        let moved = queryTab("Moved")

        let result = merge(restored: saved, restoredSelection: saved[0].id, present: [moved], presentSelection: moved.id)

        #expect(result.selectedTabId == moved.id)
    }

    @Test("With nothing present, the saved selection is restored")
    func restoredSelectionWithoutPresentTabs() {
        let saved = [queryTab("Saved A"), queryTab("Saved B")]

        let result = merge(restored: saved, restoredSelection: saved[1].id)

        #expect(result.tabs.map(\.id) == saved.map(\.id))
        #expect(result.selectedTabId == saved[1].id)
    }

    @Test("A saved selection that names no kept tab falls back to the first")
    func missingRestoredSelectionFallsBack() {
        let saved = [queryTab("Saved A"), queryTab("Saved B")]

        let result = merge(restored: saved, restoredSelection: UUID())

        #expect(result.selectedTabId == saved[0].id)
    }

    @Test("A saved tab already present is kept once, as the present copy")
    func presentIdIsNotDuplicated() {
        let saved = queryTab("Query 1")
        var present = saved
        present.content.query = "SELECT 'edited'"

        let result = merge(restored: [saved], present: [present], presentSelection: present.id)

        #expect(result.tabs.count == 1)
        #expect(result.tabs.first?.content.query == "SELECT 'edited'")
        #expect(result.restoredTabIds.isEmpty)
    }

    @Test("A saved tab another window holds is left to that window")
    func heldElsewhereIsSkipped() {
        let saved = [queryTab("Saved A"), queryTab("Detached")]

        let result = merge(restored: saved, heldElsewhere: [saved[1].id])

        #expect(result.tabs.map(\.id) == [saved[0].id])
    }

    /// The regression this guards: the saved tab's unsaved text was dropped because another tab
    /// opened the same file first.
    @Test("A saved file tab with unsaved text is kept beside the present tab on that file")
    func dirtySavedFileTabIsKept() {
        var savedFile = queryTab("cleanup.sql", file: "cleanup.sql")
        savedFile.content.savedFileContent = "SELECT 'on disk'"
        let presentFile = queryTab("cleanup.sql", file: "cleanup.sql")

        let result = merge(restored: [savedFile], present: [presentFile], presentSelection: presentFile.id)

        #expect(result.tabs.map(\.id) == [savedFile.id, presentFile.id])
        #expect(result.selectedTabId == presentFile.id)
    }

    @Test("A saved file tab is dropped when a present tab has the same file open")
    func fileTabIsDeduplicated() {
        let savedFile = queryTab("cleanup.sql", file: "cleanup.sql")
        let savedOther = queryTab("Query 1")
        let movedFile = queryTab("cleanup.sql", file: "cleanup.sql")

        let result = merge(restored: [savedFile, savedOther], present: [movedFile], presentSelection: movedFile.id)

        #expect(result.tabs.map(\.id) == [savedOther.id, movedFile.id])
    }

    @Test("A present default title that repeats a saved one is renumbered")
    func collidingPresentTitleIsRenumbered() {
        let saved = [queryTab("Query 1"), queryTab("Query 2")]
        let present = queryTab("Query 1")

        let result = merge(restored: saved, present: [present], presentSelection: present.id)

        #expect(result.tabs.last?.title == "Query 3")
        #expect(result.renamedTabIds == [present.id])
        #expect(result.tabs.prefix(2).map(\.title) == ["Query 1", "Query 2"])
    }

    @Test("A present title of the user's own is kept even when a saved tab shares it")
    func customPresentTitleIsKept() {
        let saved = [queryTab("Report")]
        let present = queryTab("Report")

        let result = merge(restored: saved, present: [present], presentSelection: present.id)

        #expect(result.tabs.map(\.title) == ["Report", "Report"])
        #expect(result.renamedTabIds.isEmpty)
    }

    // MARK: - Restore decision
}
