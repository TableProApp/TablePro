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

/// Popover content for quick connection switching
struct ConnectionSwitcherPopover: View {
    @State private var savedConnections: [DatabaseConnection] = []
    @State private var isConnecting: UUID?
    @State private var selectedIndex: Int = 0

    @Environment(\.openWindow) private var openWindow

    /// Callback when the popover should dismiss
    var onDismiss: (() -> Void)?

    private var activeSessions: [UUID: ConnectionSession] {
        DatabaseManager.shared.activeSessions
    }

    private var currentSessionId: UUID? {
        DatabaseManager.shared.currentSessionId
    }

    /// All items in display order for keyboard navigation
    private var allItems: [ConnectionItem] {
        var items: [ConnectionItem] = []

        let sorted = Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
        for session in sorted {
            items.append(.session(session))
        }

        let inactive = savedConnections.filter { activeSessions[$0.id] == nil }
        for connection in inactive {
            items.append(.saved(connection))
        }

        return items
    }

    var body: some View {
        let sortedSessions = Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
        let inactiveSaved = savedConnections.filter { activeSessions[$0.id] == nil }

        VStack(spacing: 0) {
            List {
                // Active connections section
                if !sortedSessions.isEmpty {
                    Section {
                        ForEach(Array(sortedSessions.enumerated()), id: \.element.id) { index, session in
                            Button(action: { switchToSession(session.id) }) {
                                connectionRow(
                                    connection: session.connection,
                                    isActive: session.id == currentSessionId,
                                    isConnected: session.status.isConnected,
                                    isHighlighted: index == selectedIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        index == selectedIndex
                                            ? Color(nsColor: .selectedContentBackgroundColor)
                                            : Color.clear
                                    )
                                    .padding(.horizontal, 4)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        Text("ACTIVE CONNECTIONS")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                // Saved connections (not currently active)
                if !inactiveSaved.isEmpty {
                    Section {
                        ForEach(Array(inactiveSaved.enumerated()), id: \.element.id) { index, connection in
                            let itemIndex = sortedSessions.count + index
                            Button(action: { connectToSaved(connection) }) {
                                connectionRow(
                                    connection: connection,
                                    isActive: false,
                                    isConnected: false,
                                    isConnecting: isConnecting == connection.id,
                                    isHighlighted: itemIndex == selectedIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        itemIndex == selectedIndex
                                            ? Color(nsColor: .selectedContentBackgroundColor)
                                            : Color.clear
                                    )
                                    .padding(.horizontal, 4)
                            )
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .listRowSeparator(.hidden)
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

            // Manage connections button
            Button {
                onDismiss?()
                NotificationCenter.default.post(name: .openWelcomeWindow, object: nil)
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
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .frame(
            width: 280,
            height: listHeight(
                sessions: sortedSessions.count,
                saved: inactiveSaved.count
            )
        )
        .onAppear {
            savedConnections = ConnectionStorage.shared.loadConnections()
            if let currentId = currentSessionId {
                let sorted = Array(activeSessions.values).sorted { $0.lastActiveAt > $1.lastActiveAt }
                if let idx = sorted.firstIndex(where: { $0.id == currentId }) {
                    selectedIndex = idx
                }
            }
        }
        .onExitCommand { onDismiss?() }
        .onKeyPress(.return) {
            let items = allItems
            guard selectedIndex >= 0, selectedIndex < items.count else { return .ignored }
            switch items[selectedIndex] {
            case .session(let session): switchToSession(session.id)
            case .saved(let connection): connectToSaved(connection)
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
        }
        .onKeyPress(characters: .init(charactersIn: "j"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            return moveSelection(by: 1)
        }
        .onKeyPress(characters: .init(charactersIn: "k"), phases: [.down, .repeat]) { keyPress in
            guard keyPress.modifiers.contains(.control) else { return .ignored }
            return moveSelection(by: -1)
        }
    }

    // MARK: - Item Type

    private enum ConnectionItem {
        case session(ConnectionSession)
        case saved(DatabaseConnection)
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let newIndex = selectedIndex + offset
        guard newIndex >= 0, newIndex < allItems.count else { return .handled }
        selectedIndex = newIndex
        return .handled
    }

    // MARK: - Subviews

    private func connectionRow(
        connection: DatabaseConnection,
        isActive: Bool,
        isConnected: Bool,
        isConnecting: Bool = false,
        isHighlighted: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            // Color indicator
            Circle()
                .fill(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : connection.displayColor)
                .frame(width: 8, height: 8)

            // Connection info
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                    .lineLimit(1)

                Text(connectionSubtitle(connection))
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.7) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Status indicator
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .systemGreen))
                    .font(.system(size: 14))
            } else if isConnected {
                Circle()
                    .fill(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .systemGreen))
                    .frame(width: 6, height: 6)
            }

            // Database type badge
            Text(connection.type.rawValue.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.2) : Color(nsColor: .separatorColor))
                )
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Layout

    /// Calculates popover height based on content to avoid excess whitespace
    private func listHeight(sessions: Int, saved: Int) -> CGFloat {
        let rowHeight: CGFloat = 44
        let sectionHeaderHeight: CGFloat = 28
        let buttonHeight: CGFloat = 44 // Manage Connections + divider
        var height: CGFloat = buttonHeight

        if sessions > 0 {
            height += sectionHeaderHeight + CGFloat(sessions) * rowHeight
        }
        if saved > 0 {
            height += sectionHeaderHeight + CGFloat(saved) * rowHeight
        }

        // Cap at reasonable max so it scrolls with many connections
        return min(height, 400)
    }

    // MARK: - Helpers

    private func connectionSubtitle(_ connection: DatabaseConnection) -> String {
        if PluginManager.shared.connectionMode(for: connection.type) == .fileBased {
            return connection.database
        }
        let port = connection.port != connection.type.defaultPort ? ":\(connection.port)" : ""
        return "\(connection.host)\(port)/\(connection.database)"
    }

    private func switchToSession(_ sessionId: UUID) {
        onDismiss?()
        // Try to bring existing window for this connection to front
        if let existingWindow = findWindow(for: sessionId) {
            existingWindow.makeKeyAndOrderFront(nil)
        } else {
            openWindowForDifferentConnection(EditorTabPayload(connectionId: sessionId))
        }
    }

    private func connectToSaved(_ connection: DatabaseConnection) {
        isConnecting = connection.id
        onDismiss?()
        // Open a new window, then connect — window shows "Connecting..." until ready
        openWindowForDifferentConnection(EditorTabPayload(connectionId: connection.id))
        Task {
            do {
                try await DatabaseManager.shared.connectToSession(connection)
            } catch {
                await MainActor.run {
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Connection Failed"),
                        message: error.localizedDescription,
                        window: NSApp.keyWindow
                    )
                }
            }
            await MainActor.run {
                isConnecting = nil
            }
        }
    }

    /// Find an existing visible window for the given connection ID
    private func findWindow(for connectionId: UUID) -> NSWindow? {
        WindowLifecycleMonitor.shared.findWindow(for: connectionId)
    }

    /// Open a new window for a different connection, ensuring it doesn't
    /// merge as a tab with the current connection's window group
    /// (unless the user opted to group all connections in one window).
    private func openWindowForDifferentConnection(_ payload: EditorTabPayload) {
        if AppSettingsManager.shared.tabs.groupAllConnectionTabs {
            WindowManager.shared.openTab(payload: payload)
        } else {
            // Temporarily disable tab merging so the new window opens independently
            let currentWindow = NSApp.keyWindow
            let previousMode = currentWindow?.tabbingMode ?? .preferred
            currentWindow?.tabbingMode = .disallowed
            WindowManager.shared.openTab(payload: payload)
            DispatchQueue.main.async {
                currentWindow?.tabbingMode = previousMode
            }
        }
    }
}
