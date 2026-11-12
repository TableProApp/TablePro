//
//  RunEndsEditorCompletionTests.swift
//  TableProTests
//
//  A completion popup left open after a run covers the results until Escape. Every run path ends the
//  editor's completion session in the coordinator's own window first.
//

import AppKit
import Foundation
import Testing

@testable import TablePro

@MainActor
struct RunEndsEditorCompletionTests {
    /// Blank text runs nothing, so no case reaches a driver or the execution gate, and each one still shows
    /// that the session ends before the run decides what to execute.
    @Test("Run, Run Statement and Run All end the completion session in the coordinator's window")
    func everyRunPathEndsTheSession() {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.coordinator.runQuery(viewport: .keepPlace)
        harness.coordinator.runQuery(viewport: .keepPlace, bypassRowLimit: true)
        harness.coordinator.runStatement("   ", sourceOffset: 0)
        harness.coordinator.runAllStatements()

        #expect(harness.recorder.windows.count == 4)
        #expect(harness.recorder.windows.allSatisfy { $0 === harness.window })
    }

    @Test("A run refused because the tab is already running leaves the session alone")
    func refusedRunLeavesTheSession() throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let tabId = try #require(harness.tabManager.selectedTabId)
        let claim = harness.coordinator.tabExecution.claim(tabId)
        defer { _ = harness.coordinator.tabExecution.settle(claim) }

        harness.coordinator.runQuery(viewport: .keepPlace)
        harness.coordinator.runStatement("SELECT 1", sourceOffset: 0)

        #expect(harness.recorder.windows.isEmpty)
    }
}

@MainActor
private final class WindowRecorder {
    var windows: [NSWindow?] = []
}

/// A coordinator with one blank query tab selected, a window of its own and no session behind it.
@MainActor
private struct Harness {
    let coordinator: MainContentCoordinator
    let tabManager: QueryTabManager
    let window: NSWindow
    let recorder = WindowRecorder()

    init() {
        tabManager = QueryTabManager()
        coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(type: .sqlite),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        coordinator.contentWindow = window
        let recorder = recorder
        coordinator.dismissEditorCompletions = { recorder.windows.append($0) }
        let tab = QueryTab(title: "Query", query: "   ", tabType: .query)
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
    }

    func tearDown() {
        coordinator.cancelAllQueryTasks()
        coordinator.teardown()
        window.orderOut(nil)
    }
}
