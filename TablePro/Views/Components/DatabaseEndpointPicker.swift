//
//  DatabaseEndpointPicker.swift
//  TablePro
//
//  Choosing the database an operation reads or writes.
//
//  This was an NSMenu whose submenus fetched on open, which cannot work:
//  AppKit runs a tracking session in `NSEventTrackingRunLoopMode`, the main
//  actor's executor is not drained in that mode, and a menu's `menuNeedsUpdate`
//  runs at most once per session. So the fetch never started while the menu was
//  up, and the "Loading…" row it left behind could never be replaced, however
//  many times the pointer went away and came back. A popover is the macOS idiom
//  for a toolbar control that reveals a chooser, and it runs an ordinary event
//  loop where `.task` and a spinner both behave.
//

import AppKit
import SwiftUI

internal enum DatabaseEndpointSide: Hashable {
    case source
    case target

    internal var title: String {
        switch self {
        case .source: return String(localized: "Source")
        case .target: return String(localized: "Target")
        }
    }

    /// What the toolbar button reads before anything is chosen. Neither side is preselected, so
    /// the write side of a comparison is always something the user named.
    internal var placeholderTitle: String {
        String(format: String(localized: "Choose %@"), title)
    }

    internal var caption: String {
        switch self {
        case .source: return String(localized: "Will not change")
        case .target: return String(localized: "Will be changed")
        }
    }

    internal var symbol: String {
        switch self {
        case .source: return "arrow.up.right.square"
        case .target: return "arrow.down.right.square"
        }
    }
}

internal struct DatabaseEndpointPicker: View {
    internal let side: DatabaseEndpointSide
    internal let current: DatabaseEndpoint?
    internal let onPick: (DatabaseEndpoint) -> Void
    internal let dismiss: () -> Void

    internal static let contentSize = NSSize(width: 320, height: 400)

    @State private var model = DatabaseEndpointPickerModel()
    @State private var path: [DatabaseEndpointRoute] = []
    @State private var connections: [DatabaseConnection] = []

    internal var body: some View {
        NavigationStack(path: $path) {
            connectionList
                .navigationTitle(side.title)
                .navigationDestination(for: DatabaseEndpointRoute.self) { route in
                    destination(route)
                }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .onAppear { connections = ConnectionStorage.shared.loadConnections() }
    }

    // MARK: - Connections

    private var connectionList: some View {
        Group {
            if connections.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Connections", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Add a connection first.")
                }
            } else {
                List(connections) { connection in
                    connectionRow(connection)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func connectionRow(_ connection: DatabaseConnection) -> some View {
        let endpoint = DatabaseEndpoint.from(connection: connection)
        if side == .target, let reason = endpoint.ineligibleAsTargetReason {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(connection.name)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                swatch(connection.color)
            }
            .foregroundStyle(.tertiary)
        } else {
            NavigationLink(value: DatabaseEndpointRoute.databases(connection.id)) {
                Label {
                    Text(connection.name)
                } icon: {
                    swatch(connection.color)
                }
            }
        }
    }

    // MARK: - Databases and schemas

    @ViewBuilder
    private func destination(_ route: DatabaseEndpointRoute) -> some View {
        switch route {
        case let .databases(connectionId):
            if let connection = connections.first(where: { $0.id == connectionId }) {
                databaseList(connection)
                    .navigationTitle(connection.name)
                    .task { await model.loadDatabases(for: connection) }
            }
        case let .schemas(endpoint, connectionId):
            if let connection = connections.first(where: { $0.id == connectionId }) {
                schemaList(endpoint, connection: connection)
                    .navigationTitle(endpoint.databaseLabel)
                    .task { await model.loadSchemas(for: endpoint, connection: connection) }
            }
        }
    }

    @ViewBuilder
    private func databaseList(_ connection: DatabaseConnection) -> some View {
        switch model.databases(for: connection.id) {
        case .loading:
            loadingPane
        case let .failed(message):
            failurePane(message) { await model.loadDatabases(for: connection, reload: true) }
        case let .loaded(names):
            let base = DatabaseEndpoint.from(connection: connection)
            if names.isEmpty {
                List {
                    endpointRow(base, title: base.databaseLabel.isEmpty ? connection.name : base.databaseLabel)
                }
                .listStyle(.inset)
            } else {
                List(names, id: \.self) { name in
                    databaseRow(base.withDatabase(name, label: label(name, connection)), connection: connection)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func databaseRow(_ endpoint: DatabaseEndpoint, connection: DatabaseConnection) -> some View {
        if PluginManager.shared.supportsSchemaSwitching(for: connection.type) {
            NavigationLink(value: DatabaseEndpointRoute.schemas(endpoint, connection.id)) {
                Text(endpoint.databaseLabel)
            }
        } else {
            endpointRow(endpoint, title: endpoint.databaseLabel)
        }
    }

    /// There is deliberately no "All schemas". Comparing every schema at once reads two schemas'
    /// same-named tables as one object, and the generated ALTER carries no schema of its own, so it
    /// would land on whichever schema the connection happens to be on.
    @ViewBuilder
    private func schemaList(_ endpoint: DatabaseEndpoint, connection: DatabaseConnection) -> some View {
        switch model.schemas(for: endpoint) {
        case .loading:
            loadingPane
        case let .failed(message):
            failurePane(message) { await model.loadSchemas(for: endpoint, connection: connection, reload: true) }
        case let .loaded(names):
            if names.isEmpty {
                ContentUnavailableView {
                    Label("No Schemas", systemImage: "tray")
                } description: {
                    Text("This database reports no schemas.")
                }
            } else {
                List(names, id: \.self) { name in
                    endpointRow(endpoint.withSchema(name), title: name)
                }
                .listStyle(.inset)
            }
        }
    }

    private func endpointRow(_ endpoint: DatabaseEndpoint, title: String) -> some View {
        Button {
            onPick(endpoint)
            dismiss()
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                if current?.id == endpoint.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(endpoint.fullDescription)
    }

    // MARK: - States

    private var loadingPane: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Connecting…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failurePane(_ message: String, retry: @escaping () async -> Void) -> some View {
        ContentUnavailableView {
            Label("Cannot Read This Connection", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await retry() }
            }
        }
    }

    private func swatch(_ color: ConnectionColor) -> some View {
        Circle()
            .fill(color == .none ? Color.secondary.opacity(0.35) : color.color)
            .frame(width: 10, height: 10)
    }

    private func label(_ database: String, _ connection: DatabaseConnection) -> String {
        DatabaseEndpoint.label(for: database, type: connection.type)
    }
}

internal enum DatabaseEndpointRoute: Hashable {
    case databases(UUID)
    case schemas(DatabaseEndpoint, UUID)
}
