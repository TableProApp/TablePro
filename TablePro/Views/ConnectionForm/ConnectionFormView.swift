//
//  ConnectionFormView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ConnectionFormView: View {
    let connectionId: UUID?

    @State private var coordinator: ConnectionFormCoordinator?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let coordinator {
                ConnectionFormContent(coordinator: coordinator, dismiss: dismiss)
            } else {
                Color.clear
                    .frame(minWidth: 720, minHeight: 560)
            }
        }
        .task(id: connectionId) {
            guard coordinator == nil else { return }
            let pendingImport = connectionId == nil
                ? PendingNewConnectionImport.shared.consume()
                : nil
            let pendingType = connectionId == nil
                ? PendingNewConnectionType.shared.consume()
                : nil
            let new = ConnectionFormCoordinator(
                connectionId: connectionId,
                initialType: pendingType,
                initialParsedURL: pendingImport
            )
            new.dismissAction = { dismiss() }
            new.start()
            new.detectClipboardConnectionStringIfNeeded()
            coordinator = new
        }
    }
}

private struct ConnectionFormContent: View {
    @Bindable var coordinator: ConnectionFormCoordinator
    let dismiss: DismissAction

    var body: some View {
        NavigationSplitView {
            ConnectionFormSidebar(coordinator: coordinator)
        } detail: {
            ConnectionFormDetail(coordinator: coordinator)
        }
        .frame(minWidth: 720, idealWidth: 820)
        .frame(minHeight: 560, idealHeight: 600)
        .navigationTitle(
            coordinator.isNew
                ? String(format: String(localized: "New %@ Connection"), coordinator.network.type.rawValue)
                : String(format: String(localized: "Edit %@ Connection"), coordinator.network.type.rawValue)
        )
        .toolbar {
            ConnectionFormToolbar(coordinator: coordinator)
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
}

private struct ConnectionFormDetail: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        Group {
            switch coordinator.selectedPane {
            case .general:
                GeneralPaneView(coordinator: coordinator)
            case .ssh:
                SSHPaneView(coordinator: coordinator)
            case .ssl:
                SSLPaneView(coordinator: coordinator)
            case .customization:
                CustomizationPaneView(coordinator: coordinator)
            case .advanced:
                AdvancedPaneView(coordinator: coordinator)
            case .aiRules:
                AIRulesPaneView(coordinator: coordinator)
            }
        }
        .navigationSplitViewColumnWidth(min: 480, ideal: 580)
    }
}
