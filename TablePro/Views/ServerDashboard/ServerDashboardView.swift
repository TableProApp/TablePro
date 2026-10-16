import SwiftUI

struct ServerDashboardView: View {
    @ObservedObject var viewModel: ServerDashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardToolbarView(viewModel: viewModel)
            Divider()

            if viewModel.supportedPanels.isEmpty {
                UnavailableStateView(
                    String(localized: "Dashboard Not Available"),
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: Text("Server monitoring is not available for this database type.")
                )
            } else {
                ServerDashboardSplitView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.startAutoRefresh() }
        .onDisappear { viewModel.stopAutoRefresh() }
        .alert(
            String(localized: "Terminate Session"),
            isPresented: $viewModel.showKillConfirmation,
            presenting: viewModel.pendingKillSession
        ) { _ in
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.pendingKillSession = nil }
            Button(String(localized: "Terminate"), role: .destructive) {
                Task { await viewModel.executeKillSession() }
            }
        } message: { session in
            Text(ServerDashboardViewModel.killConfirmationMessage(for: session))
        }
        .alert(
            String(localized: "Cancel Query"),
            isPresented: $viewModel.showCancelConfirmation,
            presenting: viewModel.pendingCancelSession
        ) { _ in
            Button(String(localized: "Keep Running"), role: .cancel) { viewModel.pendingCancelSession = nil }
            Button(String(localized: "Cancel Query"), role: .destructive) {
                Task { await viewModel.executeCancelQuery() }
            }
        } message: { session in
            Text(ServerDashboardViewModel.cancelConfirmationMessage(for: session))
        }
        .alert(String(localized: "Action Failed"), isPresented: Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )) {
            Button(String(localized: "OK"), role: .cancel) { viewModel.actionError = nil }
        } message: {
            if let error = viewModel.actionError {
                Text(verbatim: RevealedText(error).plainText)
            }
        }
    }
}
