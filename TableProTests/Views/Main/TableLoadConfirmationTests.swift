//
//  TableLoadConfirmationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

/// Alert (Full) and Safe Mode (Full) confirm every table load, retargets included, because a
/// retarget clears the tab's last run.
@MainActor
struct TableLoadConfirmationTests {
    /// A retarget raises the loading flag before the load asks. Cancel used to leave it up, so the
    /// status bar read Loading over the error with its pagination disabled.
    @Test("Cancelling the confirmation lowers the loading flag and shows why")
    func cancelLowersTheLoadingFlag() async {
        let harness = Harness(gate: HeldGate(firstAnswer: .denied(reason: "Cancelled")))
        defer { harness.tearDown() }
        let tabId = harness.addTableTab("users")

        let confirmation = harness.coordinator.executeTableTabQueryDirectly(viewport: .firstRow)
        await harness.gate.release()
        await confirmation?.value

        let tab = harness.coordinator.tabManager.tabs.first { $0.id == tabId }
        #expect(tab?.execution.errorMessage == "Cancelled")
        #expect(tab?.pagination.isLoading == false)
        #expect(harness.driver.sentStatements.isEmpty)
    }

    /// The sheet holds the window, but a link or an agent can select another table under it. The
    /// approval used to run the first table's SELECT on whichever tab was selected by then.
    @Test("An approval that arrives after another tab was selected does not run there")
    func approvalAfterSelectionChangeDoesNotRun() async {
        let harness = Harness(gate: HeldGate(firstAnswer: .authorized(Self.receipt)))
        defer { harness.tearDown() }
        let firstId = harness.addTableTab("users")

        let confirmation = harness.coordinator.executeTableTabQueryDirectly(viewport: .firstRow)
        await harness.gate.untilAsked()
        let secondId = harness.addTableTab("orders")
        await harness.gate.release()
        await confirmation?.value
        await harness.coordinator.tableLoadTasks[secondId]?.task.value
        await harness.coordinator.queryTasks.task(for: secondId)?.value

        #expect(!harness.driver.sentStatements.contains { $0.contains("users") })
        let first = harness.coordinator.tabManager.tabs.first { $0.id == firstId }
        #expect(first?.pagination.isLoading == false)
        #expect(harness.coordinator.tabExecution.isExecuting(firstId) == false)
    }

    private static let receipt = OperationReceipt(
        connectionId: UUID(),
        kind: .readQuery,
        effectiveWrite: false,
        grantedAt: Date(),
        token: UUID()
    )

    // MARK: - Harness

    /// Holds the first answer until the test releases it and denies every later request, so a
    /// second load reaching the gate settles instead of waiting forever.
    private actor HeldGate: ExecutionGate {
        private let firstAnswer: OperationDecision
        private var held: CheckedContinuation<Void, Never>?
        private var askedWaiters: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false
        private var requestCount = 0

        init(firstAnswer: OperationDecision) {
            self.firstAnswer = firstAnswer
        }

        func authorize(_ request: OperationRequest) async -> OperationDecision {
            requestCount += 1
            guard requestCount == 1 else { return .denied(reason: "Later load") }
            askedWaiters.forEach { $0.resume() }
            askedWaiters = []
            if !isReleased {
                await withCheckedContinuation { held = $0 }
            }
            return firstAnswer
        }

        func untilAsked() async {
            guard requestCount == 0 else { return }
            await withCheckedContinuation { askedWaiters.append($0) }
        }

        func release() {
            isReleased = true
            held?.resume()
            held = nil
        }
    }

    @MainActor
    private struct Harness {
        let coordinator: MainContentCoordinator
        let connection: DatabaseConnection
        let driver: ScriptAnsweringDriver
        let gate: HeldGate

        init(gate: HeldGate) {
            let connection = DatabaseConnection(
                name: "Confirm", database: "app", type: .postgresql, safeModeLevel: .alertFull
            )
            let driver = ScriptAnsweringDriver(connection: connection, sendsBatchesWhole: false)
            var session = ConnectionSession(connection: connection, driver: driver)
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: connection.id)

            let toolbarState = ConnectionToolbarState()
            toolbarState.safeModeLevel = .alertFull
            let coordinator = MainContentCoordinator(
                connection: connection,
                tabManager: QueryTabManager(),
                changeManager: DataChangeManager(),
                toolbarState: toolbarState
            )
            coordinator.executionGate = gate

            self.coordinator = coordinator
            self.connection = connection
            self.driver = driver
            self.gate = gate
        }

        /// The state a retarget leaves: a table that has never run, with its loading flag raised.
        func addTableTab(_ tableName: String) -> UUID {
            var tab = QueryTab(
                title: tableName,
                query: "SELECT * FROM \(tableName) LIMIT 1000",
                tabType: .table,
                tableName: tableName
            )
            tab.pagination.isLoading = true
            coordinator.tabManager.tabs.append(tab)
            coordinator.tabManager.selectedTabId = tab.id
            return tab.id
        }

        func tearDown() {
            coordinator.cancelAllQueryTasks()
            DatabaseManager.shared.removeSession(for: connection.id)
            coordinator.teardown()
        }
    }
}
