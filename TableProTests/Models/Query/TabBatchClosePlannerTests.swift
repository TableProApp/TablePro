//
//  TabBatchClosePlannerTests.swift
//  TableProTests
//
//  Covers which windows a bulk close targets and which one survives (#1972).
//

import Foundation
import Testing

@testable import TablePro

private final class WindowToken {}

@Suite("TabBatchClosePlanner")
struct TabBatchClosePlannerTests {
    private let current = WindowToken()
    private let second = WindowToken()
    private let third = WindowToken()

    private var currentId: ObjectIdentifier { ObjectIdentifier(current) }
    private var secondId: ObjectIdentifier { ObjectIdentifier(second) }
    private var thirdId: ObjectIdentifier { ObjectIdentifier(third) }

    private func target(_ token: WindowToken, databases: Set<String> = []) -> TabBatchCloseTarget {
        TabBatchCloseTarget(windowId: ObjectIdentifier(token), databaseNames: databases)
    }

    // MARK: - Close All

    @Test("closing all keeps the invoking window as the survivor")
    func closeAllKeepsCurrentWindowAsSurvivor() {
        let plan = TabBatchClosePlanner.planCloseAll(
            targets: [target(second), target(current), target(third)],
            currentWindowId: currentId
        )

        #expect(plan.windowsToCloseOutright == [secondId, thirdId])
        #expect(plan.survivorWindowId == currentId)
    }

    @Test("closing all with only the invoking window still empties it")
    func closeAllWithSingleWindowStillHasSurvivor() {
        let plan = TabBatchClosePlanner.planCloseAll(targets: [target(current)], currentWindowId: currentId)

        #expect(plan.windowsToCloseOutright.isEmpty)
        #expect(plan.survivorWindowId == currentId)
        #expect(!plan.isEmpty)
    }

    // MARK: - Close Others

    @Test("closing others targets the same windows but keeps no survivor")
    func closeOthersHasNoSurvivor() {
        let plan = TabBatchClosePlanner.planCloseOthers(
            targets: [target(second), target(current), target(third)],
            currentWindowId: currentId
        )

        #expect(plan.windowsToCloseOutright == [secondId, thirdId])
        #expect(plan.survivorWindowId == nil)
    }

    @Test("closing others is a no-op when the invoking window is alone")
    func closeOthersWithSingleWindowIsEmpty() {
        let plan = TabBatchClosePlanner.planCloseOthers(targets: [target(current)], currentWindowId: currentId)

        #expect(plan.isEmpty)
    }

    // MARK: - Close for other databases

    @Test("only windows whose every tab names another database are closed")
    func closeForOtherDatabasesTargetsForeignWindowsOnly() {
        let plan = TabBatchClosePlanner.planCloseForOtherDatabases(
            targets: [target(current, databases: ["db_a"]), target(second, databases: ["db_b"])],
            currentWindowId: currentId,
            currentDatabaseName: "db_a"
        )

        #expect(plan.windowsToCloseOutright == [secondId])
        #expect(plan.survivorWindowId == nil)
    }

    @Test("a window holding a tab for the active database is kept")
    func closeForOtherDatabasesKeepsMixedWindow() {
        let plan = TabBatchClosePlanner.planCloseForOtherDatabases(
            targets: [target(second, databases: ["db_a", "db_b"])],
            currentWindowId: currentId,
            currentDatabaseName: "db_a"
        )

        #expect(plan.isEmpty)
    }

    @Test("a window with no named database follows the connection and is kept")
    func closeForOtherDatabasesKeepsUnnamedWindow() {
        let plan = TabBatchClosePlanner.planCloseForOtherDatabases(
            targets: [target(second)],
            currentWindowId: currentId,
            currentDatabaseName: "db_a"
        )

        #expect(plan.isEmpty)
    }

    @Test("the invoking window is never closed even when it names another database")
    func closeForOtherDatabasesNeverClosesCurrentWindow() {
        let plan = TabBatchClosePlanner.planCloseForOtherDatabases(
            targets: [target(current, databases: ["db_b"])],
            currentWindowId: currentId,
            currentDatabaseName: "db_a"
        )

        #expect(plan.isEmpty)
    }

    @Test("an unknown active database closes nothing")
    func closeForOtherDatabasesWithoutActiveDatabaseIsEmpty() {
        let plan = TabBatchClosePlanner.planCloseForOtherDatabases(
            targets: [target(second, databases: ["db_b"]), target(third, databases: ["db_c"])],
            currentWindowId: currentId,
            currentDatabaseName: ""
        )

        #expect(plan.isEmpty)
    }
}
