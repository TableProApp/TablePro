//
//  ConnectionSwitcherPopover.swift
//  TablePro
//
//  Quick-switch popover for active and saved connections.
//  Shown from the toolbar connection button.
//

import AppKit
import SwiftUI
import TableProPluginKit

struct ConnectionSwitcherPopover: View {
    @State private var savedConnections: [DatabaseConnection] = []
    @State private var selectedConnectionId: UUID?

    var onDismiss: (() -> Void)?

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

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedConnectionId) {
                if !sortedSessions.isEmpty {
                    Section {
                        ForEach(sortedSessions) { session in
                            connectionRow(
                                connection: session.connection,
                                isActive: session.id == currentSessionId,
                                isConnected: session.status.isConnected
                            )
                            .tag(session.id)
                        }
                    } header: {
                        Text("ACTIVE CONNECTIONS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if !inactiveSaved.isEmpty {
                    Section {
                        ForEach(inactiveSaved) { connection in
                            connectionRow(connection: connection, isActive: false, isConnected: false)
                                .tag(connection.id)
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

            Divider()

            Button {
                onDismiss?()
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
        .frame(
            width: 280,
            height: listHeight(sessions: sortedSessions.count, saved: inactiveSaved.count)
        )
        .onAppear {
            savedConnections = ConnectionStorage.shared.loadConnections()
            if selectedConnectionId == nil {
                selectedConnectionId = currentSessionId ?? sortedSessions.first?.id ?? inactiveSaved.first?.id
            }
        }
        .onExitCommand { onDismiss?() }
        .onKeyPress(.return) {
            activateSelected()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "j"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "k"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
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
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .font(.body)
            } else if isConnected {
                Circle()
                    .fill(Color(nsColor: .systemGreen))
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

    private var allConnectionIds: [UUID] {
        sortedSessions.map(\.id) + inactiveSaved.map(\.id)
    }

    private func moveSelection(by offset: Int) {
        let ids = allConnectionIds
        guard !ids.isEmpty else { return }
        let currentIndex = ids.firstIndex(of: selectedConnectionId ?? UUID()) ?? 0
        let newIndex = max(0, min(ids.count - 1, currentIndex + offset))
        selectedConnectionId = ids[newIndex]
    }

    private func activateSelected() {
        guard let id = selectedConnectionId else { return }
        activate(connectionId: id)
    }

    private func activate(connectionId: UUID) {
        onDismiss?()
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

    // MARK: - Layout

    private func listHeight(sessions: Int, saved: Int) -> CGFloat {
        let rowHeight: CGFloat = 44
        let sectionHeaderHeight: CGFloat = 28
        let buttonHeight: CGFloat = 44
        var height: CGFloat = buttonHeight
        if sessions > 0 {
            height += sectionHeaderHeight + CGFloat(sessions) * rowHeight
        }
        if saved > 0 {
            height += sectionHeaderHeight + CGFloat(saved) * rowHeight
        }
        return min(height, 400)
    }

    private func connectionSubtitle(_ connection: DatabaseConnection) -> String {
        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased {
            return connection.database
        }
        let port = connection.port != connection.type.defaultPort ? ":\(connection.port)" : ""
        return "\(connection.host)\(port)/\(connection.database)"
    }
}
