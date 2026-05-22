//
//  ConnectionSwitcherPopover.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

enum ConnectionSwitcherFilter {
    static func matches(_ connection: DatabaseConnection, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        let needle = trimmed.lowercased()
        return connection.name.lowercased().contains(needle)
            || connection.host.lowercased().contains(needle)
            || connection.database.lowercased().contains(needle)
    }
}

enum ConnectionSwitcherSelection {
    static func moved(in ids: [UUID], from current: UUID?, by offset: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        let currentIndex = current.flatMap { ids.firstIndex(of: $0) } ?? 0
        let newIndex = max(0, min(ids.count - 1, currentIndex + offset))
        return ids[newIndex]
    }
}

struct ConnectionSwitcherPopover: View {
    @Environment(\.dismiss) private var dismiss

    @State private var savedConnections: [DatabaseConnection] = []
    @State private var selectedConnectionId: UUID?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private static let popoverWidth: CGFloat = 400
    private static let popoverHeight: CGFloat = 460

    private var activeSessions: [UUID: ConnectionSession] {
        DatabaseManager.shared.activeSessions
    }

    private var currentSessionId: UUID? {
        DatabaseManager.shared.currentSessionId
    }

    private var sortedSessions: [ConnectionSession] {
        Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    private var inactiveSaved: [DatabaseConnection] {
        savedConnections.filter { activeSessions[$0.id] == nil }
    }

    private var filteredSessions: [ConnectionSession] {
        sortedSessions.filter { ConnectionSwitcherFilter.matches($0.connection, query: searchText) }
    }

    private var filteredSaved: [DatabaseConnection] {
        inactiveSaved.filter { ConnectionSwitcherFilter.matches($0, query: searchText) }
    }

    private var orderedIds: [UUID] {
        filteredSessions.map(\.id) + filteredSaved.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content

            Divider()

            manageButton
        }
        .frame(width: Self.popoverWidth, height: Self.popoverHeight)
        .onAppear {
            savedConnections = ConnectionStorage.shared.loadConnections()
            if selectedConnectionId == nil {
                selectedConnectionId = currentSessionId ?? orderedIds.first
            }
            searchFocused = true
        }
        .onChange(of: searchText) { _, _ in
            let ids = orderedIds
            if let id = selectedConnectionId, ids.contains(id) { return }
            selectedConnectionId = ids.first
        }
        .onKeyPress(.return) {
            activateSelected()
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: 14)

            TextField(
                "",
                text: $searchText,
                prompt: Text(String(localized: "Search connections"))
                    .foregroundStyle(.tertiary)
            )
            .textFieldStyle(.plain)
            .font(.body)
            .focused($searchFocused)
            .onKeyPress(.downArrow) {
                moveSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                moveSelection(by: -1)
                return .handled
            }
            .onKeyPress(.return) {
                activateSelected()
                return .handled
            }
            .onKeyPress(.escape) {
                if searchText.isEmpty { return .ignored }
                searchText = ""
                return .handled
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        if orderedIds.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedConnectionId) {
                if !filteredSessions.isEmpty {
                    Section {
                        ForEach(filteredSessions) { session in
                            connectionRow(
                                connection: session.connection,
                                isActive: session.id == currentSessionId,
                                isConnected: session.status.isConnected
                            )
                            .tag(session.id)
                            .id(session.id)
                        }
                    } header: {
                        Text("ACTIVE CONNECTIONS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if !filteredSaved.isEmpty {
                    Section {
                        ForEach(filteredSaved) { connection in
                            connectionRow(connection: connection, isActive: false, isConnected: false)
                                .tag(connection.id)
                                .id(connection.id)
                        }
                    } header: {
                        Text("SAVED CONNECTIONS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: selectedConnectionId) { _, newValue in
                guard let id = newValue else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            if searchText.isEmpty {
                Text(String(localized: "No connections"))
                    .font(.callout.weight(.medium))
            } else {
                Text(String(format: String(localized: "No connections match “%@”"), searchText))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var manageButton: some View {
        Button {
            dismiss()
            WindowOpener.shared.openWelcome()
        } label: {
            HStack {
                Image(systemName: "gear")
                    .foregroundStyle(.secondary)
                Text("Manage Connections...")
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func connectionRow(
        connection: DatabaseConnection,
        isActive: Bool,
        isConnected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connection.displayColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)

                Text(connectionSubtitle(connection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body)
            } else if isConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }

            Text(connection.type.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color(nsColor: .separatorColor), in: RoundedRectangle(cornerRadius: 3))
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { activate(connectionId: connection.id) }
    }

    // MARK: - Selection

    private func moveSelection(by offset: Int) {
        if let next = ConnectionSwitcherSelection.moved(in: orderedIds, from: selectedConnectionId, by: offset) {
            selectedConnectionId = next
        }
    }

    private func activateSelected() {
        guard let id = selectedConnectionId else { return }
        activate(connectionId: id)
    }

    private func activate(connectionId: UUID) {
        dismiss()
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connectionId))
            } catch {
                await MainActor.run {
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Connection Failed"),
                        message: error.localizedDescription,
                        window: NSApp.keyWindow
                    )
                }
            }
        }
    }

    private func connectionSubtitle(_ connection: DatabaseConnection) -> String {
        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased {
            return connection.database
        }
        let port = connection.port != connection.type.defaultPort ? ":\(connection.port)" : ""
        return "\(connection.host)\(port)/\(connection.database)"
    }
}
