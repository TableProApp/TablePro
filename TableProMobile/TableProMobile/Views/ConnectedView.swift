//
//  ConnectedView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels

struct ConnectedView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    let connection: DatabaseConnection

    @State private var coordinator: ConnectionCoordinator?
    @State private var hapticSuccess = false
    @State private var hapticError = false

    var body: some View {
        Group {
            if let coordinator {
                switch coordinator.phase {
                case .connecting:
                    connectingView
                case .error(let error):
                    ErrorView(error: error) {
                        await coordinator.connect()
                    }
                case .connected:
                    connectedContent(coordinator)
                }
            } else {
                connectingView
            }
        }
        .task {
            let c = ConnectionCoordinator(connection: connection, appState: appState)
            coordinator = c
            c.restorePersistedState()
            await c.connect()
            if !Task.isCancelled {
                c.loadHistory()
                hapticSuccess.toggle()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await coordinator?.reconnectIfNeeded() }
            }
        }
        .sensoryFeedback(.success, trigger: hapticSuccess)
        .sensoryFeedback(.error, trigger: hapticError)
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView {
                Text(String(format: String(localized: "Connecting to %@..."),
                             connection.name.isEmpty ? connection.host : connection.name))
            }
            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connected Content

    private func connectedContent(_ coordinator: ConnectionCoordinator) -> some View {
        @Bindable var coordinator = coordinator
        return TabView(selection: $coordinator.selectedTab) {
            Tab("Tables", systemImage: "tablecells", value: .tables) {
                NavigationStack(path: $coordinator.tablesPath) {
                    TableListView()
                        .navigationTitle(coordinator.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            Tab("Query", systemImage: "terminal", value: .query) {
                NavigationStack {
                    QueryEditorView()
                }
            }
            Tab("History", systemImage: "clock", value: .history) {
                NavigationStack {
                    QueryHistoryView()
                }
            }
            Tab("Settings", systemImage: "gear", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(coordinator as ConnectionCoordinator)
        .background {
            Button("") { coordinator.selectedTab = .tables }
                .keyboardShortcut("1", modifiers: .command)
                .hidden()
            Button("") { coordinator.selectedTab = .query }
                .keyboardShortcut("2", modifiers: .command)
                .hidden()
            Button("") { coordinator.selectedTab = .history }
                .keyboardShortcut("3", modifiers: .command)
                .hidden()
            Button("") { coordinator.selectedTab = .settings }
                .keyboardShortcut("4", modifiers: .command)
                .hidden()
        }
        .overlay(alignment: .top) {
            if coordinator.isReconnecting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(localized: "Reconnecting..."))
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 4)
            }
        }
        .animation(.default, value: coordinator.isReconnecting)
        .allowsHitTesting(!coordinator.isSwitching)
        .overlay {
            if coordinator.isSwitching {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: coordinator.isSwitching)
        .alert("Error", isPresented: $coordinator.showFailureAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.failureAlertMessage ?? "")
        }
        .userActivity("com.TablePro.viewConnection") { activity in
            activity.title = connection.name.isEmpty ? connection.host : connection.name
            activity.isEligibleForHandoff = true
            activity.userInfo = ["connectionId": connection.id.uuidString]
        }
    }
}
