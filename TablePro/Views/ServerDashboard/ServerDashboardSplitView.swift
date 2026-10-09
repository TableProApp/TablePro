import AppKit
import SwiftUI

struct ServerDashboardSplitView: NSViewControllerRepresentable {
    /// Observed, not just held. As a plain reference the representable compared equal to itself on
    /// every refresh, so SwiftUI never called `updateNSViewController` and the metrics and slow
    /// query panes kept the empty values they were built with: Server Metrics never left its
    /// spinner. The sessions pane only updated because `SessionsTableView` observes the model itself.
    @ObservedObject var viewModel: ServerDashboardViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let splitViewController = ServerDashboardSplitViewController()
        splitViewController.splitView.isVertical = false
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = SplitViewAutosaveName.current("ServerDashboardSplit")

        for panel in orderedPanels() {
            let item = makeItem(for: panel, coordinator: context.coordinator)
            splitViewController.addSplitViewItem(item)
        }

        return splitViewController
    }

    /// `NSSplitViewItem.minimumThickness` is a required constraint, so this controller reports
    /// the summed minimums as its fitting size. SwiftUI turns that into a `minWidth` that outranks
    /// a divider drag, which kills the window's own dividers.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: NSSplitViewController,
        context: Context
    ) -> CGSize? {
        let resolved = proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: Self.naturalSize, height: Self.naturalSize)
        )
        guard resolved.width.isFinite, resolved.height.isFinite else { return nil }
        return resolved
    }

    private static let naturalSize: CGFloat = 480

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
            controller.sizingOptions = []
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
            controller.sizingOptions = []
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 76
            item.maximumThickness = 200
            item.holdingPriority = .splitPaneHolding
            coordinator.metricsController = controller
            return item

        case .slowQueries:
            let controller = NSHostingController(
                rootView: SlowQueryListView(
                    queries: viewModel.slowQueries,
                    error: viewModel.panelErrors[.slowQueries]
                )
            )
            controller.sizingOptions = []
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 100
            item.holdingPriority = .splitPaneHolding
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

/// No dashboard pane collapses, because a collapsed last pane loses its divider and nothing else
/// reopens it. A record autosaved while the slow query pane could still be dragged shut brings it
/// back collapsed anyway, applied by the time the split view reaches a window.
@MainActor
internal final class ServerDashboardSplitViewController: ResizeCursorSplitViewController {
    override internal func viewWillAppear() {
        super.viewWillAppear()
        for item in splitViewItems where item.isCollapsed {
            item.isCollapsed = false
        }
    }
}
