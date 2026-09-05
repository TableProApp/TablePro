//
//  ConnectionFormView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ConnectionFormView: View {
    let request: ConnectionFormRequest?
    let close: () -> Void

    @State private var coordinator: ConnectionFormCoordinator?

    var body: some View {
        Group {
            if let coordinator {
                ConnectionFormContent(coordinator: coordinator)
            } else {
                Color.clear
                    .frame(minWidth: 640, minHeight: 560)
            }
        }
        .task(id: request) {
            guard coordinator == nil else { return }
            let draft = consumeDraft()
            let new = ConnectionFormCoordinator(
                connectionId: request?.editedConnectionId,
                initialType: draft?.type,
                initialParsedURL: draft?.parsedURL
            )
            new.dismissAction = close
            new.start()
            new.detectClipboardConnectionStringIfNeeded()
            coordinator = new
        }
    }

    private func consumeDraft() -> ConnectionFormDraft? {
        guard let draftId = request?.draftId else { return nil }
        return ConnectionFormDraftStore.shared.consume(draftId)
    }
}

/// A tab bar over one grouped form, with the commit actions on a bottom bar.
///
/// The bar is where the validation message lives, so the reason Save is disabled sits beside the
/// disabled button rather than nowhere: the issue strings each pane computes used to be reduced
/// to a warning triangle and thrown away.
private struct ConnectionFormContent: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                ConnectionFormSidebar(coordinator: coordinator)
            } detail: {
                selectedPane
                    /// On the detail pane rather than beside the diagnostic sheet below: two
                    /// `.sheet` modifiers on one view resolve to a single presenter on macOS, so
                    /// whichever lost would keep its binding true with nothing on screen, and
                    /// Change… would go dead.
                    .sheet(isPresented: $coordinator.isChoosingType) {
                        DatabaseTypeChooserSheet(
                            initialType: coordinator.network.type,
                            onSelected: { coordinator.changeType(to: $0) },
                            onCancel: { coordinator.isChoosingType = false }
                        )
                    }
            }
            /// The four sections are the window's only navigation and the set never changes, so
            /// there is nothing for a collapse to reveal, and a collapsed sidebar would persist
            /// through the window's frame autosave and reopen the editor with no way to move.
            .toolbar(removing: .sidebarToggle)

            Divider()

            /// The bar is wrapped around the split view rather than applied as a
            /// `.safeAreaInset(edge: .bottom)`. Measured on a 620pt window: wrapping leaves the
            /// split 571pt and puts the bar under both columns, while the inset leaves the split
            /// its full 620 and pushes the bar inside them.
            ConnectionFormActionBar(coordinator: coordinator)
        }
        .frame(minWidth: 720, idealWidth: 820)
        .frame(minHeight: 560, idealHeight: 620)
        .navigationTitle(windowTitle)
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

    private var windowTitle: String {
        coordinator.isNew
            ? String(format: String(localized: "New %@ Connection"), coordinator.network.type.rawValue)
            : String(format: String(localized: "Edit %@ Connection"), coordinator.network.type.rawValue)
    }
}
