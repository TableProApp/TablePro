import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("QueryTab protection predicates")
struct QueryTabProtectionTests {
    @Test("A blank scratch query tab holds no work")
    func blankScratchTabHoldsNoWork() {
        let tab = QueryTab(query: "   \n\t ")
        #expect(!tab.holdsQueryWork)
        #expect(!tab.isReopenCandidate)
        #expect(!tab.showsUnsavedIndicator)
    }

    @Test("Typed SQL in a scratch tab is reopenable work and shows the unsaved dot")
    func typedScratchTabIsProtected() {
        let tab = QueryTab(query: "SELECT 1")
        #expect(tab.holdsQueryWork)
        #expect(tab.isReopenCandidate)
        #expect(tab.showsUnsavedIndicator)
    }

    @Test("An executed but empty query tab is not reusable, yet has nothing to reopen")
    func executedEmptyTabIsNotReusableButNotReopenable() {
        var tab = QueryTab(query: "")
        tab.execution.lastExecutedAt = Date()
        #expect(tab.holdsQueryWork)
        #expect(!tab.isReopenCandidate)
        #expect(!tab.showsUnsavedIndicator)
    }

    @Test("A file-backed tab matching disk is clean")
    func fileBackedTabMatchingDiskIsClean() {
        var tab = QueryTab(query: "SELECT 1")
        tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/query.sql")
        tab.content.savedFileContent = "SELECT 1"
        #expect(!tab.showsUnsavedIndicator)
        #expect(tab.isReopenCandidate)
    }

    @Test("A file-backed tab diverging from disk shows the unsaved dot")
    func fileBackedTabDivergingFromDiskIsDirty() {
        var tab = QueryTab(query: "SELECT 2")
        tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/query.sql")
        tab.content.savedFileContent = "SELECT 1"
        #expect(tab.showsUnsavedIndicator)
    }

    @Test("A table tab is reopenable but never shows the unsaved dot")
    func tableTabIsReopenable() {
        let tab = QueryTab(query: "SELECT * FROM users", tabType: .table, tableName: "users")
        #expect(tab.isReopenCandidate)
        #expect(!tab.showsUnsavedIndicator)
        #expect(!tab.holdsQueryWork)
    }

    @Test("Utility tabs carry no reopenable content")
    func utilityTabsAreNotReopenable() {
        let tab = QueryTab(query: "", tabType: .usersRoles)
        #expect(!tab.isReopenCandidate)
        #expect(!tab.showsUnsavedIndicator)
    }
}
