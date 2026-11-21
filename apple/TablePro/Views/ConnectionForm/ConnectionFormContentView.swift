//
//  ConnectionFormContentView.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

/// The whole connection editor as one scrolling grouped `Form` over the commit bar.
///
/// A connection is a single object, so it reads top to bottom rather than through a sidebar of
/// peer sections (HIG: a tab bar, or one grouped form, before a source list). The rarely-set
/// options sit behind one disclosure so a plain connection shows only identity, where it lives,
/// who signs in, how it travels, and how it looks.
struct ConnectionFormContentView: View {
    @ObservedObject var coordinator: ConnectionFormCoordinator
    @FocusState private var nameFocused: Bool
    @State private var showsAdvanced = false

    var body: some View {
        Group {
            if coordinator.isRecordMissing {
                recordMissingView
            } else {
                editorBody
            }
        }
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
        .pluginInstallPrompt(for: $coordinator.pluginInstallConnection, type: \.type) { _ in
            coordinator.test()
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

    private var editorBody: some View {
        VStack(spacing: 0) {
            Form {
                GeneralPaneView(coordinator: coordinator, nameFocused: $nameFocused)
                if coordinator.showsNetworkFacet {
                    NetworkPaneView(coordinator: coordinator)
                }
                AppearancePaneView(coordinator: coordinator)
                advancedSection
                if showsAdvanced {
                    OptionsPaneView(coordinator: coordinator)
                }
            }
            .formStyle(.grouped)
            .defaultFocus($nameFocused, true)
            .task(id: coordinator.auth.pgpassLookup) {
                coordinator.auth.updatePgpassStatus()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            ConnectionFormActionBar(coordinator: coordinator)
        }
    }

    private var recordMissingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(String(localized: "Connection Not Found"))
                .font(.headline)
            Text(String(localized: "This connection was deleted on another device or window."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Close")) {
                coordinator.cancel()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            Button {
                withMotion(.snappy(duration: 0.2)) { showsAdvanced.toggle() }
            } label: {
                HStack {
                    Text(String(localized: "Advanced Options"))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("connection-form-advanced-disclosure")
            .accessibilityLabel(String(localized: "Advanced Options"))
            .accessibilityValue(showsAdvanced
                ? String(localized: "Expanded")
                : String(localized: "Collapsed"))
        }
    }
}

/// Hosts the form and keeps the window title on the connection's type, which `Change…` can alter.
///
/// `NSWindow(contentViewController:)` binds the window title to this controller's own, so nothing
/// writes `window.title` directly.
@MainActor
final class ConnectionFormContentViewController: NSHostingController<ConnectionFormContentView> {
    private let coordinator: ConnectionFormCoordinator
    private var titleObservations: [AnyCancellable] = []

    init(coordinator: ConnectionFormCoordinator) {
        self.coordinator = coordinator
        super.init(rootView: ConnectionFormContentView(coordinator: coordinator))
        trackTitle()
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func trackTitle() {
        title = windowTitle
        titleObservations = [
            coordinator.onMainActorChange { [weak self] in
                guard let self else { return }
                self.title = self.windowTitle
            },
        ]
    }

    private var windowTitle: String {
        coordinator.isNew
            ? String(format: String(localized: "New %@ Connection"), coordinator.network.type.rawValue)
            : String(format: String(localized: "Edit %@ Connection"), coordinator.network.type.rawValue)
    }
}
