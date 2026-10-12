//
//  CancelledExecutionOwnershipTests.swift
//  TableProTests
//
//  #2342. A cancelled execution used to release the tab by id, which releases whatever the tab is
//  running now rather than what the cancelled claim started. Two loads for one sidebar click was
//  enough to hit it: the first, cancelled by the second, deleted the second's claim on its way out,
//  and the second's own `settle` then refused to apply the rows it had already fetched. The grid
//  stayed empty until the reader clicked a different table and came back.
//
//  The same class of mistake reached the close path from the other side: a closed tab kept its
//  claim, and Reopen Closed Tab hands the restored tab the id it had before.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct CancelledExecutionOwnershipTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private func addTableTab(to tabManager: QueryTabManager, tableName: String = "users") -> UUID {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.tableContext.isEditable = true
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    private func neverEndingTask() -> Task<Void, Never> {
        Task { _ = try? await Task.sleep(for: .seconds(60)) }
    }

    @Test("A cancelled execution cannot release the claim that superseded it")
    func cancelledExecutionLeavesTheSuccessorOwningTheTab() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)

        let superseded = coordinator.tabExecution.claim(tabId)
        _ = coordinator.tabExecution.invalidate(tabId, reason: .supersededNavigation)
        let live = coordinator.tabExecution.claim(tabId)

        coordinator.resetExecutionState(claim: superseded, executionTime: 0)

        #expect(coordinator.tabExecution.isCurrent(live))
        let settled = coordinator.tabExecution.settle(live)
        #expect(settled)
    }

    /// The whole point of the fix: the successor's rows have to reach the grid. `settle` returning
    /// true is the successor's authority to write them.
    @Test("The superseding execution can still apply its result")
    func supersedingExecutionStillApplies() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)

        let superseded = coordinator.tabExecution.claim(tabId)
        _ = coordinator.tabExecution.invalidate(tabId, reason: .supersededNavigation)
        let live = coordinator.tabExecution.claim(tabId)
        let capturedContent = coordinator.tabExecution.contentEpoch(for: tabId)

        coordinator.resetExecutionState(claim: superseded, executionTime: 0)

        #expect(coordinator.tabExecution.isSameContent(capturedContent, for: tabId))
        #expect(coordinator.tabExecution.ownsContent(live))
    }

    @Test("A cancelled execution that still owns the tab releases it")
    func cancelledCurrentExecutionReleasesTheTab() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)

        let claim = coordinator.tabExecution.claim(tabId)
        coordinator.resetExecutionState(claim: claim, executionTime: 0)

        #expect(coordinator.tabExecution.isExecuting(tabId) == false)
        #expect(coordinator.tabExecution.isAnyExecuting == false)
    }

    @Test("A cancelled execution does not retire the successor's query handle")
    func cancelledExecutionLeavesTheSuccessorsHandleInstalled() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)

        let superseded = coordinator.tabExecution.claim(tabId)
        _ = coordinator.tabExecution.invalidate(tabId, reason: .supersededNavigation)
        let live = coordinator.tabExecution.claim(tabId)
        let handle = neverEndingTask()
        defer { handle.cancel() }
        coordinator.installQueryTask(handle, owner: .claim(live), lease: DriverLeaseOwner())

        coordinator.resetExecutionState(claim: superseded, executionTime: 12)

        #expect(coordinator.queryTasks.hasTask(for: tabId))
        #expect(coordinator.toolbarState.queryTimings.isEmpty)
    }

    /// Stop keeps a claim whose commit is already on the wire, and a script-managed batch leaves the
    /// phase and goes on running its remaining statements. Taking the handle down anyway left those
    /// statements with nothing to cancel them: Stop did nothing for the rest of the run, and the
    /// execution ended reporting a `preparationAbandoned` anomaly.
    @Test("Stop leaves the query handle of a claim it could not end")
    func stopKeepsTheHandleOfACommittingClaim() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)
        let handle = neverEndingTask()
        defer { handle.cancel() }
        coordinator.installQueryTask(handle, owner: .claim(claim), lease: DriverLeaseOwner())
        let entered = coordinator.tabExecution.enterUninterruptiblePhase(claim)
        #expect(entered)

        coordinator.stopExecution(for: tabId)

        #expect(coordinator.queryTasks.hasTask(for: tabId))
        #expect(coordinator.tabExecution.isCurrent(claim))
    }

    @Test("Stop takes down the query handle of a claim it ended")
    func stopEndsTheHandleOfAnOrdinaryClaim() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)
        let handle = neverEndingTask()
        defer { handle.cancel() }
        coordinator.installQueryTask(handle, owner: .claim(claim), lease: DriverLeaseOwner())

        coordinator.stopExecution(for: tabId)

        #expect(coordinator.queryTasks.hasTask(for: tabId) == false)
        #expect(coordinator.tabExecution.isCurrent(claim) == false)
    }

    @Test("Closing a tab releases the execution it was running")
    func closingATabReleasesItsExecution() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager)
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            Issue.record("expected the tab to exist")
            return
        }
        let claim = coordinator.tabExecution.claim(tabId)

        coordinator.releaseExecution(of: tab)

        #expect(coordinator.tabExecution.isCurrent(claim) == false)
        #expect(coordinator.tabExecution.isBusy(tabId) == false)
        #expect(coordinator.tabExecution.isAnyExecuting == false)
    }

    /// Each tab owns its own handle, so closing one takes its handle down and leaves every other
    /// tab's where it is.
    @Test("Closing a tab leaves another tab's query handle alone")
    func closingATabLeavesAnotherTabsHandleAlone() {
        let (coordinator, tabManager) = makeCoordinator()
        let closing = addTableTab(to: tabManager, tableName: "closing")
        let other = addTableTab(to: tabManager, tableName: "other")
        guard let closingTab = tabManager.tabs.first(where: { $0.id == closing }) else {
            Issue.record("expected the closing tab to exist")
            return
        }
        let closingClaim = coordinator.tabExecution.claim(closing)
        let otherClaim = coordinator.tabExecution.claim(other)
        let closingHandle = neverEndingTask()
        let otherHandle = neverEndingTask()
        defer {
            closingHandle.cancel()
            otherHandle.cancel()
        }
        coordinator.installQueryTask(closingHandle, owner: .claim(closingClaim), lease: DriverLeaseOwner())
        coordinator.installQueryTask(otherHandle, owner: .claim(otherClaim), lease: DriverLeaseOwner())

        coordinator.releaseExecution(of: closingTab)

        #expect(coordinator.queryTasks.hasTask(for: closing) == false)
        #expect(coordinator.queryTasks.hasTask(for: other))
        #expect(coordinator.tabExecution.isCurrent(otherClaim))
    }

    /// The behaviour above is only reached if the close path asks for it, and driving
    /// `closeTabsByUser` from a unit test would write to the reader's own recently-closed store.
    @Test("The user close path releases the execution")
    func closeTabsByUserReleasesTheExecution() throws {
        let body = try Self.functionBody(named: "closeTabsByUser", in: "MainContentCoordinator+TabClosing.swift")
        #expect(
            body.contains("releaseExecution(of: tab)"),
            "closeTabsByUser must release the tab's execution before removing the tab"
        )
    }

    private static func functionBody(named name: String, in fileName: String) throws -> String {
        let url = try repoRoot()
            .appendingPathComponent("TablePro/Views/Main/Extensions")
            .appendingPathComponent(fileName)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.contains("func \(name)(") }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var depth = 0
        var body = ""
        for line in lines[start...] {
            body += line + "\n"
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if depth == 0, body.contains("{") { break }
        }
        return body
    }

    private static func repoRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("TablePro.xcodeproj").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
