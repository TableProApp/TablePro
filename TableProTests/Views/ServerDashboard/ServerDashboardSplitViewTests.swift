//
//  ServerDashboardSplitViewTests.swift
//  TableProTests
//
//  The metrics and slow query panes are hosting controllers inside an `NSSplitViewController`, so
//  they only see a refresh when SwiftUI calls `updateNSViewController`. Holding the view model as a
//  plain reference made the representable compare equal on every refresh and skip that call, which
//  left Server Metrics on its spinner for as long as the tab stayed open.
//

import AppKit
import SwiftUI
import Testing

@testable import TablePro

@MainActor
struct ServerDashboardSplitViewTests {
    @Test("A refresh reaches the metrics and slow query panes")
    func refreshReachesHostedPanes() async throws {
        let viewModel = ServerDashboardViewModel(connectionId: UUID(), databaseType: .mysql, services: .live)
        let window = host(ServerDashboardView(viewModel: viewModel))
        defer {
            viewModel.stopAutoRefresh()
            window.orderOut(nil)
            window.contentView = nil
        }

        let splitController = try #require(splitViewController(in: window.contentView))
        #expect(metrics(in: splitController)?.isEmpty == true)

        viewModel.metrics = [
            DashboardMetric(id: "uptime", label: "Uptime", value: "3", unit: "days", icon: "clock")
        ]
        viewModel.slowQueries = [
            DashboardSlowQuery(duration: "4s", query: "SELECT SLEEP(4)", user: "app", database: "shop")
        ]

        #expect(await settle(window) { metrics(in: splitController)?.count == 1 })
        #expect(slowQueries(in: splitController)?.count == 1)
    }

    /// A collapsed last pane loses its divider, so a pane dragged shut could never be dragged back.
    @Test("No dashboard pane can be dragged shut")
    func panesRefuseDrag() throws {
        let viewModel = ServerDashboardViewModel(connectionId: UUID(), databaseType: .mysql, services: .live)
        let window = host(ServerDashboardView(viewModel: viewModel))
        defer {
            viewModel.stopAutoRefresh()
            window.orderOut(nil)
            window.contentView = nil
        }

        let splitController = try #require(splitViewController(in: window.contentView))
        let last = try #require(splitController.splitViewItems.last)
        #expect(splitController.splitViewItems.allSatisfy { !$0.canCollapse })

        splitController.splitView.setPosition(
            splitController.splitView.bounds.height,
            ofDividerAt: splitController.splitViewItems.count - 2
        )
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(!last.isCollapsed)
    }

    /// Stands in for a record autosaved while the slow query pane could still be dragged shut, which
    /// AppKit applies before the split view reaches a window.
    @Test("A pane restored collapsed opens when the dashboard appears")
    func restoredCollapseReopens() throws {
        let controller = ServerDashboardSplitViewController()
        controller.splitView.isVertical = false
        for _ in 0 ..< 3 {
            let pane = NSViewController()
            pane.view = NSView()
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 80
            controller.addSplitViewItem(item)
        }
        let last = try #require(controller.splitViewItems.last)
        last.isCollapsed = true

        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 800, height: 600))
        defer { window.close() }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(!last.isCollapsed)
    }

    private func host(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func settle(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func splitViewController(in view: NSView?) -> NSSplitViewController? {
        guard let view else { return nil }
        if let splitView = view as? NSSplitView, let controller = splitView.delegate as? NSSplitViewController {
            return controller
        }
        for subview in view.subviews {
            if let found = splitViewController(in: subview) { return found }
        }
        return nil
    }

    private func metrics(in controller: NSSplitViewController) -> [DashboardMetric]? {
        controller.splitViewItems
            .compactMap { $0.viewController as? NSHostingController<MetricsBarView> }
            .first?.rootView.metrics
    }

    private func slowQueries(in controller: NSSplitViewController) -> [DashboardSlowQuery]? {
        controller.splitViewItems
            .compactMap { $0.viewController as? NSHostingController<SlowQueryListView> }
            .first?.rootView.queries
    }
}
