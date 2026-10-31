//
//  UserTypeTabStateTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct UserTypeTabStateTests {
    private func typeTab(_ fixture: CoordinatorFixture, select: Bool = true) -> (QueryTab, UserTypeEditorModel) {
        let ref = DatabaseObjectRef(
            userType: UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "app"),
            database: "shop"
        )
        var tab = QueryTab(title: QueryTabManager.objectSourceTitle(for: ref), tabType: .objectSource)
        tab.display.objectRef = ref
        fixture.addTab(tab, select: select)
        let model = fixture.coordinator.makeUserTypeEditor(for: ref, tabId: tab.id)
        fixture.coordinator.userTypeEditors[tab.id] = model
        return (tab, model)
    }

    @Test("A type tab's queue lights the commit control and survives a structure view clearing its own flag")
    func queueOwnsItsFlag() {
        let fixture = CoordinatorFixture()
        let (tab, model) = typeTab(fixture)
        model.stage(.addEnumLabel("glad", placement: nil))

        fixture.coordinator.publishUserTypeEditorState(tabId: tab.id, hasChanges: model.hasChanges)

        #expect(fixture.coordinator.toolbarState.hasTypeChanges)
    }

    @Test("Leaving a type tab sets the flag for the tab now selected, whichever order the views report in")
    func leavingFollowsTheSelection() {
        let fixture = CoordinatorFixture()
        let (first, firstModel) = typeTab(fixture)
        let (second, secondModel) = typeTab(fixture)
        firstModel.stage(.addEnumLabel("glad", placement: nil))

        fixture.tabManager.selectedTabId = second.id
        fixture.coordinator.publishUserTypeEditorState(tabId: second.id, hasChanges: secondModel.hasChanges)
        fixture.coordinator.releaseUserTypeEditorState(tabId: first.id)
        #expect(!fixture.coordinator.toolbarState.hasTypeChanges)

        fixture.tabManager.selectedTabId = first.id
        fixture.coordinator.releaseUserTypeEditorState(tabId: second.id)
        #expect(fixture.coordinator.toolbarState.hasTypeChanges)
    }

    @Test("A background type tab with a queue is unsaved work Save can reach")
    func backgroundQueueIsSaveable() {
        let fixture = CoordinatorFixture()
        let (tab, model) = typeTab(fixture, select: false)
        #expect(fixture.coordinator.savability(of: tab) == .nothingAtRisk)

        model.stage(.addEnumLabel("glad", placement: nil))
        #expect(fixture.coordinator.savability(of: tab) == .saveable)
        #expect(fixture.coordinator.hasUnsavedWork(forTab: tab.id))
    }

    @Test("A queued name is shown as typed, even while the queue refuses it")
    func queuedNameIsKeptAsTyped() {
        let fixture = CoordinatorFixture()
        let (_, model) = typeTab(fixture)
        model.stage(.rename(to: ""))
        #expect(model.queuedName == "")
    }
}
