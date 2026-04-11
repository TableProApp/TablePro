import SwiftUI

struct ServerDashboardView: View {
    @Bindable var viewModel: ServerDashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardToolbarView(viewModel: viewModel)
            Divider()

            if viewModel.supportedPanels.isEmpty {
                ContentUnavailableView(
                    String(localized: "Dashboard Not Available"),
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: Text("Server monitoring is not available for this database type.")
                )
            } else {
                VStack(spacing: 0) {
                    if viewModel.supportedPanels.contains(.activeSessions) {
                        SessionsTableView(viewModel: viewModel)
                    }

                    if viewModel.supportedPanels.contains(.serverMetrics) {
                        Divider()
                        MetricsBarView(
                            metrics: viewModel.metrics,
                            error: viewModel.panelErrors[.serverMetrics]
                        )
                    }

                    if viewModel.supportedPanels.contains(.slowQueries) {
                        Divider()
                        SlowQueryListView(
                            queries: viewModel.slowQueries,
                            error: viewModel.panelErrors[.slowQueries]
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
        .alert(String(localized: "Terminate Session"), isPresented: $viewModel.showKillConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.pendingKillProcessId = nil }
            Button(String(localized: "Terminate"), role: .destructive) {
                Task { await viewModel.executeKillSession() }
            }
        } message: {
            Text(String(localized: "Are you sure you want to terminate this session? Any running queries will be aborted."))
        }
        .alert(String(localized: "Cancel Query"), isPresented: $viewModel.showCancelConfirmation) {
            Button(String(localized: "Keep Running"), role: .cancel) { viewModel.pendingCancelProcessId = nil }
            Button(String(localized: "Cancel Query"), role: .destructive) {
                Task { await viewModel.executeCancelQuery() }
            }
        } message: {
            Text(String(localized: "Are you sure you want to cancel the running query for this session?"))
        }
        .alert(String(localized: "Action Failed"), isPresented: Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { viewModel.actionError = nil }
        } message: {
            if let error = viewModel.actionError {
                Text(error)
            }
        }
    }
}
