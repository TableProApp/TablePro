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

    /// Counts real deliveries rather than re-asserting the single-mount case on a fresh coordinator,
    /// which is what the leak actually was: registrations accumulating across mounts. A block
    /// observer is NOT dropped when its token deallocates (measured), so a torn-down mount whose
    /// observer was left on keeps answering this notification forever.
    @Test("observers from earlier mounts stop answering once those mounts are gone")
    func earlierMountsStopAnswering() {
        var scrollViews: [NSScrollView] = []
        var coordinators: [TableViewCoordinator] = []
        for _ in 0..<5 {
            let coordinator = makeCoordinator()
            let scrollView = makeScrollView(for: coordinator)
            coordinator.attachScrollObservers(scrollView: scrollView)
            DataGridView.dismantleNSView(scrollView, coordinator: coordinator)
            coordinators.append(coordinator)
            scrollViews.append(scrollView)
        }

        for coordinator in coordinators {
            #expect(coordinator.scrollObservers.isEmpty)
            #expect(!coordinator.hasAccessibilityActivationObserver)
        }

        /// Posting for every torn-down scroll view must reach nothing. Before the fix each of these
        /// still had three live registrations.
        for scrollView in scrollViews {
            NotificationCenter.default.post(
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }
    }

    /// The row gutter registers a fourth observer per mount, from `installRowGutter`. Its own
    /// comment used to claim `NotificationCenter` drops a block observer when the token dies, which
    /// is measurably false, so it was never taken off.
    @Test("unmounting the grid takes the row gutter's geometry observer off")
    func dismantleDetachesGutterObserver() {
        let coordinator = makeCoordinator()
        let scrollView = makeScrollView(for: coordinator)
        let gutter = DataGridRowGutterView(frame: .zero)
        gutter.coordinator = coordinator
        coordinator.rowGutter = gutter
        gutter.observeTableGeometry()
        #expect(gutter.hasTableGeometryObserver)

        DataGridView.dismantleNSView(scrollView, coordinator: coordinator)

        #expect(!gutter.hasTableGeometryObserver)
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
