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
            tabPicker
            Divider()
            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                /// On the pane rather than beside the diagnostic sheet below: two `.sheet`
                /// modifiers on one view resolve to a single presenter on macOS, so whichever lost
                /// would keep its binding true with nothing on screen, and Change… would go dead.
                .sheet(isPresented: $coordinator.isChoosingType) {
                    DatabaseTypeChooserSheet(
                        initialType: coordinator.network.type,
                        onSelected: { coordinator.changeType(to: $0) },
                        onCancel: { coordinator.isChoosingType = false }
                    )
                }
            Divider()
            ConnectionFormActionBar(coordinator: coordinator)
        }
        .frame(minWidth: 640, idealWidth: 720)
        .frame(minHeight: 560, idealHeight: 640)
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

    /// `NSSegmentedControl` rather than a `TabView`. SwiftUI's macOS tab bar was redesigned in
    /// macOS 26 and renders `.tabItem { Text }` as a collapsed stub here, and a segmented control
    /// is what AppKit puts above the content of a window that edits one object anyway.
    private var tabPicker: some View {
        Picker(String(localized: "Section"), selection: $coordinator.selectedTab) {
            ForEach(coordinator.visibleTabs) { tab in
                Text(tab.title).tag(tab)
            }
        }
        /// No `accessibilityIdentifier` here: on a container it replaces the identifier of every
        /// segment inside it, and the segments are reached by their own titles.
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
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
