//
//  ConnectionFormDetailView.swift
//  TablePro
//

import SwiftUI

/// The split view's detail column: the selected section over the bar that commits the window.
///
/// The bar sits inside this column rather than under both, because the window's
/// contentViewController has to be the split controller itself for `toggleSidebar(_:)` and
/// `.sidebarTrackingSeparator` to resolve. Wrapping the split view to span a bar across both
/// columns would take that away, and the sidebar has nothing to commit anyway.
struct ConnectionFormDetailView: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        VStack(spacing: 0) {
            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ConnectionFormActionBar(coordinator: coordinator)
        }
        /// On the detail column rather than beside the diagnostic sheet: two `.sheet` modifiers on
        /// one view resolve to a single presenter on macOS, so whichever lost would keep its
        /// binding true with nothing on screen, and Change… would go dead.
        .sheet(isPresented: $coordinator.isChoosingType) {
            DatabaseTypeChooserSheet(
                initialType: coordinator.network.type,
                onSelected: { coordinator.changeType(to: $0) },
                onCancel: { coordinator.isChoosingType = false }
            )
        }
        .sheet(item: $coordinator.pluginDiagnostic) { item in
            PluginDiagnosticSheet(item: item) {
                coordinator.pluginDiagnostic = nil
            }
        }
        .pluginInstallPrompt(connection: $coordinator.pluginInstallConnection) { connection in
            coordinator.connectAfterInstall(connection)
        }
        .alert(
            String(localized: "Save Failed"),
            isPresented: Binding(
                get: { coordinator.saveError != nil },
                set: { if !$0 { coordinator.saveError = nil } }
            ),
            presenting: coordinator.saveError
        ) { _ in
            Button(String(localized: "OK"), role: .cancel) {
                coordinator.saveError = nil
            }
        } message: { error in
            Text(error)
        }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch coordinator.selectedTab {
        case .general:
            GeneralPaneView(coordinator: coordinator)
        case .network:
            NetworkPaneView(coordinator: coordinator)
        case .options:
            OptionsPaneView(coordinator: coordinator)
        case .appearance:
            AppearancePaneView(coordinator: coordinator)
        }
    }
}
