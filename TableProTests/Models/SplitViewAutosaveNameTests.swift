//
//  SplitViewAutosaveNameTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SplitViewAutosaveNameTests {
    @Test("Production keeps the bare name a user's saved widths hang off")
    func productionKeepsTheBareName() {
        #expect(
            SplitViewAutosaveName.autosaveName(SplitViewAutosaveName.base, isUnitTestHost: false, isIsolated: false)
                == "com.TablePro.mainSplit"
        )
    }

    @Test("A sandboxed run names no record, so nothing reaches the real defaults domain")
    func sandboxNamesNoRecord() {
        #expect(SplitViewAutosaveName.autosaveName("MainEditorWindow", isUnitTestHost: false, isIsolated: true) == nil)
        #expect(SplitViewAutosaveName.autosaveName("MainEditorWindow", isUnitTestHost: true, isIsolated: true) == nil)
    }

    @Test("The unit test host names no autosave record, so no window it builds writes one")
    @MainActor
    func unitTestHostNamesNoRecord() {
        #expect(SplitViewAutosaveName.current(SplitViewAutosaveName.base) == nil)
        #expect(SplitViewAutosaveName.current(SplitViewAutosaveName.historyDrawer(connectionId: UUID())) == nil)
    }
}
