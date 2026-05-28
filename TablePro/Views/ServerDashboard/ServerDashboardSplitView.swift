import AppKit
import SwiftUI

struct ServerDashboardSplitView: NSViewControllerRepresentable {
    let viewModel: ServerDashboardViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = false
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = "ServerDashboardSplit"

        for panel in orderedPanels() {
            let item = makeItem(for: panel, coordinator: context.coordinator)
            splitViewController.addSplitViewItem(item)
        }

        return splitViewController
    }

    func updateNSViewController(_ splitViewController: NSSplitViewController, context: Context) {
        context.coordinator.sessionsController?.rootView = SessionsTableView(viewModel: viewModel)
        context.coordinator.metricsController?.rootView = MetricsBarView(
            metrics: viewModel.metrics,
            error: viewModel.panelErrors[.serverMetrics]
        )
        context.coordinator.slowQueriesController?.rootView = SlowQueryListView(
            queries: viewModel.slowQueries,
            error: viewModel.panelErrors[.slowQueries]
        )
    }

    private func orderedPanels() -> [DashboardPanel] {
        let supported = viewModel.supportedPanels
        let order: [DashboardPanel] = [.activeSessions, .serverMetrics, .slowQueries]
        return order.filter { supported.contains($0) }
    }

    private func makeItem(for panel: DashboardPanel, coordinator: Coordinator) -> NSSplitViewItem {
        switch panel {
        case .activeSessions:
            let controller = NSHostingController(rootView: SessionsTableView(viewModel: viewModel))
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 120
            item.holdingPriority = .defaultLow
            coordinator.sessionsController = controller
            return item

        case .serverMetrics:
            let controller = NSHostingController(
                rootView: MetricsBarView(
                    metrics: viewModel.metrics,
                    error: viewModel.panelErrors[.serverMetrics]
                )
            )
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 76
            item.maximumThickness = 200
            item.holdingPriority = .defaultHigh
            coordinator.metricsController = controller
            return item

        case .slowQueries:
            let controller = NSHostingController(
                rootView: SlowQueryListView(
                    queries: viewModel.slowQueries,
                    error: viewModel.panelErrors[.slowQueries]
                )
            )
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 100
            item.canCollapse = true
            item.holdingPriority = .defaultHigh
            coordinator.slowQueriesController = controller
            return item
        }
    }

    final class Coordinator {
        var sessionsController: NSHostingController<SessionsTableView>?
        var metricsController: NSHostingController<MetricsBarView>?
        var slowQueriesController: NSHostingController<SlowQueryListView>?
    }
}
