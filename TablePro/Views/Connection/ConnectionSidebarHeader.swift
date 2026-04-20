//
//  ConnectionSidebarHeader.swift
//  TablePro
//
//  Connection dropdown header at top of table browser sidebar
//

import SwiftUI

struct ConnectionSidebarHeader: View {
    let sessions: [ConnectionSession]
    let currentSessionId: UUID?
    let savedConnections: [DatabaseConnection]
    let onSelectSession: (UUID) -> Void
    let onOpenConnection: (DatabaseConnection) -> Void
    let onNewConnection: () -> Void

    @State private var showConnectionMenu = false

    private var currentSession: ConnectionSession? {
        guard let id = currentSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Connection selector button
            Menu {
                // Active connections
                if !sessions.isEmpty {
                    Section("Active Connections") {
                        ForEach(sortedSessions) { session in
                            Button(action: {
                                onSelectSession(session.id)
                            }) {
                                HStack {
                                    session.connection.type.iconImage
                                        .renderingMode(.template)
                                        .foregroundStyle(session.connection.displayColor)

                                    Text(session.connection.name)

                                    Spacer()

                                    // Status indicator
                                    statusIndicator(for: session)

                                    // Checkmark for active
                                    if session.id == currentSessionId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }

                // Saved connections
                if !savedConnections.isEmpty {
                    if !sessions.isEmpty {
                        Divider()
                    }

                    Section("Saved Connections") {
                        ForEach(savedConnections) { connection in
                            Button(action: {
                                onOpenConnection(connection)
                            }) {
                                HStack {
                                    connection.type.iconImage
                                        .renderingMode(.template)
                                        .foregroundStyle(connection.displayColor)

                                    Text(connection.name)
                                }
                            }
                        }
                    }
                }

                if !sessions.isEmpty || !savedConnections.isEmpty {
                    Divider()
                }

                // New connection
                Button(action: onNewConnection) {
                    Label("New Connection", systemImage: "plus.circle")
                }
            } label: {
                HStack(spacing: 8) {
                    // Database icon
                    if let session = currentSession {
                        session.connection.type.iconImage
                            .renderingMode(.template)
                            .font(.system(size: 16))
                            .foregroundStyle(session.connection.displayColor)
                    } else {
                        Image(systemName: "cylinder")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }

                    // Connection name
                    Text(currentSession?.connection.name ?? "No Connection")
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Spacer()

                    // Status + Chevron
                    HStack(spacing: 6) {
                        if let session = currentSession {
                            Circle()
                                .fill(statusColor(for: session))
                                .frame(
                                    width: 6,
                                    height: 6)
                        }

                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
        }
    }

    // MARK: - Helpers

    private var sortedSessions: [ConnectionSession] {
        sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    @ViewBuilder
    private func statusIndicator(for session: ConnectionSession) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(for: session))
                .frame(
                    width: 6,
                    height: 6)

            if case .connecting = session.status {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.5)
            }
        }
    }

    private func statusColor(for session: ConnectionSession) -> Color {
        switch session.status {
        case .connected:
            return Color(nsColor: .systemGreen)
        case .connecting:
            return Color(nsColor: .systemOrange)
        case .disconnected:
            return .gray
        case .error:
            return Color(nsColor: .systemRed)
        }
    }
}

// MARK: - Preview

#Preview("Sidebar Header") {
    let session1 = ConnectionSession(
        connection: DatabaseConnection(
            name: "MySQL Local",
            type: .mysql
        )
    )

    var session2 = ConnectionSession(
        connection: DatabaseConnection(
            name: "PostgreSQL Production",
            type: .postgresql
        )
    )
    session2.status = .connected

    let savedConnections = [
        DatabaseConnection(name: "Development DB", type: .mysql),
        DatabaseConnection(name: "Staging DB", type: .postgresql),
    ]

    return VStack(spacing: 0) {
        ConnectionSidebarHeader(
            sessions: [session1, session2],
            currentSessionId: session1.id,
            savedConnections: savedConnections,
            onSelectSession: { _ in },
            onOpenConnection: { _ in },
            onNewConnection: {}
        )

        Rectangle()
            .fill(Color(nsColor: .textBackgroundColor))
    }
    .frame(width: 250, height: 400)
}
