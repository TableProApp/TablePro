//
//  DataGridMountTeardownTests.swift
//  TableProTests
//
//  A coordinator is built fresh on every mount, and the editor mounts the grid as `.id(tab.id)`,
//  so anything the mount registers has to come off with it. `NotificationCenter` retains a block
//  observer's closure, so a registration left behind is never fired again and never reclaimed.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class StubLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("DataGridView mount teardown")
@MainActor
struct DataGridMountTeardownTests {
    private func makeCoordinator() -> TableViewCoordinator {
        TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: StubLayoutPersister()
        )
    }

    private func makeScrollView(for coordinator: TableViewCoordinator) -> NSScrollView {
        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = tableView
        coordinator.tableView = tableView
        return scrollView
    }

    @Test("unmounting the grid takes its scroll observers off the notification centre")
    func dismantleDetachesScrollObservers() {
        let coordinator = makeCoordinator()
        let scrollView = makeScrollView(for: coordinator)
        coordinator.attachScrollObservers(scrollView: scrollView)
        #expect(coordinator.scrollObservers.count == 3)

        DataGridView.dismantleNSView(scrollView, coordinator: coordinator)

        #expect(coordinator.scrollObservers.isEmpty)
    }

    @Test("unmounting the grid takes its accessibility activation observer off too")
    func dismantleDetachesAccessibilityObserver() {
        let coordinator = makeCoordinator()
        let scrollView = makeScrollView(for: coordinator)
        #expect(coordinator.hasAccessibilityActivationObserver)

        DataGridView.dismantleNSView(scrollView, coordinator: coordinator)

        #expect(!coordinator.hasAccessibilityActivationObserver)
    }

    /// The count is what the leak was: three registrations per mount, and the editor remounts the
    /// grid on every tab switch and every result-mode toggle.
    @Test("mounting and unmounting repeatedly leaves nothing registered")
    func repeatedMountsLeaveNothingBehind() {
        for _ in 0..<5 {
            let coordinator = makeCoordinator()
            let scrollView = makeScrollView(for: coordinator)
            coordinator.attachScrollObservers(scrollView: scrollView)
            DataGridView.dismantleNSView(scrollView, coordinator: coordinator)
            #expect(coordinator.scrollObservers.isEmpty)
            #expect(!coordinator.hasAccessibilityActivationObserver)
        }
    }

    @Test("detaching twice is harmless, so teardown and session release can both run")
    func detachIsIdempotent() {
        let coordinator = makeCoordinator()
        let scrollView = makeScrollView(for: coordinator)
        coordinator.attachScrollObservers(scrollView: scrollView)

        DataGridView.dismantleNSView(scrollView, coordinator: coordinator)
        coordinator.detachScrollObservers()
        coordinator.detachAccessibilityActivationObserver()

        #expect(coordinator.scrollObservers.isEmpty)
        #expect(!coordinator.hasAccessibilityActivationObserver)
    }
}
