//
//  WelcomeWindowView.swift
//  TablePro
//
//  Separate welcome window with split-panel layout.
//  Shows on app launch, closes when connecting to a database.
//

import AppKit
import os
import SwiftUI

// MARK: - WelcomeWindowView

struct WelcomeWindowView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "WelcomeWindowView")

    private enum FocusField {
        case search
        case connectionList
    }

    private let storage = ConnectionStorage.shared
    private let groupStorage = GroupStorage.shared
    private let dbManager = DatabaseManager.shared

    @State private var connections: [DatabaseConnection] = []
    @State private var searchText = ""
    @State private var showNewConnectionSheet = false
    @State private var showEditConnectionSheet = false
    @State private var connectionToEdit: DatabaseConnection?
    @State private var connectionToDelete: DatabaseConnection?
    @State private var showDeleteConfirmation = false
    @State private var hoveredConnectionId: UUID?
    @State private var selectedConnectionId: UUID?
    @FocusState private var focus: FocusField?
    @State private var showOnboarding = !AppSettingsStorage.shared.hasCompletedOnboarding()
    @State private var groups: [ConnectionGroup] = []
    @State private var collapsedGroupIds: Set<UUID> = {
        let strings = UserDefaults.standard.stringArray(forKey: "com.TablePro.collapsedGroupIds") ?? []
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }()
    @State private var showNewGroupSheet = false
    @State private var showActivationSheet = false
    @State private var pluginInstallConnection: DatabaseConnection?

    @Environment(\.openWindow) private var openWindow

    private var filteredConnections: [DatabaseConnection] {
        if searchText.isEmpty {
            return connections
        }
        return connections.filter { connection in
            connection.name.localizedCaseInsensitiveContains(searchText)
                || connection.host.localizedCaseInsensitiveContains(searchText)
                || connection.database.localizedCaseInsensitiveContains(searchText)
                || groupName(for: connection.groupId)?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private func groupName(for groupId: UUID?) -> String? {
        guard let groupId else { return nil }
        return groups.first { $0.id == groupId }?.name
    }

    private var ungroupedConnections: [DatabaseConnection] {
        let validGroupIds = Set(groups.map(\.id))
        return filteredConnections.filter { conn in
            guard let groupId = conn.groupId else { return true }
            return !validGroupIds.contains(groupId)
        }
    }

    private var activeGroups: [ConnectionGroup] {
        let groupIds = Set(filteredConnections.compactMap(\.groupId))
        return groups.filter { groupIds.contains($0.id) }
    }

    private func connections(in group: ConnectionGroup) -> [DatabaseConnection] {
        filteredConnections.filter { $0.groupId == group.id }
    }

    private var flatVisibleConnections: [DatabaseConnection] {
        var result = ungroupedConnections
        for group in activeGroups where !collapsedGroupIds.contains(group.id) {
            result.append(contentsOf: connections(in: group))
        }
        return result
    }

    var body: some View {
        ZStack {
            if showOnboarding {
                OnboardingContentView {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        showOnboarding = false
                    }
                }
                .transition(.move(edge: .leading))
            } else {
                welcomeContent
                    .transition(.move(edge: .trailing))
            }
        }
        .background(.background)
        .ignoresSafeArea()
        .frame(minWidth: 650, minHeight: 400)
        .onAppear {
            loadConnections()
        }
        .confirmationDialog(
            "Delete Connection",
            isPresented: $showDeleteConfirmation,
            presenting: connectionToDelete
        ) { connection in
            Button("Delete", role: .destructive) {
                deleteConnection(connection)
            }
            Button("Cancel", role: .cancel) {}
        } message: { connection in
            Text("Are you sure you want to delete \"\(connection.name)\"?")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            openWindow(id: "connection-form", value: nil as UUID?)
        }
        .onReceive(NotificationCenter.default.publisher(for: .connectionUpdated)) { _ in
            loadConnections()
        }
        .sheet(isPresented: $showNewGroupSheet) {
            CreateGroupSheet { name, color in
                let group = ConnectionGroup(name: name, color: color)
                groupStorage.addGroup(group)
                groups = groupStorage.loadGroups()
            }
        }
        .sheet(isPresented: $showActivationSheet) {
            LicenseActivationSheet()
        }
        .pluginInstallPrompt(connection: $pluginInstallConnection) { connection in
            connectAfterInstall(connection)
        }
    }

    private var welcomeContent: some View {
        HStack(spacing: 0) {
            // Left panel - Branding
            leftPanel

            Divider()

            // Right panel - Connections
            rightPanel
        }
        .transition(.opacity)
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            // App branding
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .shadow(color: Color(red: 1.0, green: 0.576, blue: 0.0).opacity(0.4), radius: 20, x: 0, y: 0)

                VStack(spacing: 6) {
                    Text("TablePro")
                        .font(
                            .system(
                                size: ThemeEngine.shared.activeTheme.iconSizes.extraLarge, weight: .semibold,
                                design: .rounded))

                    Text("Version \(Bundle.main.appVersion)")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                        .foregroundStyle(.secondary)

                    if LicenseManager.shared.status.isValid {
                        Label("Pro", systemImage: "checkmark.seal.fill")
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Button(action: { showActivationSheet = true }) {
                            Text("Activate License")
                                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
                .frame(height: 48)

            // Action button
            VStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://github.com/sponsors/datlechin") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Sponsor TablePro", systemImage: "heart")
                }
                .buttonStyle(.plain)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.pink)

                Button(action: { openWindow(id: "connection-form") }) {
                    Label("Create connection...", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WelcomeButtonStyle())
            }
            .padding(.horizontal, 32)

            Spacer()

            // Footer hints
            HStack(spacing: 16) {
                SyncStatusIndicator()
                KeyboardHint(keys: "⌘N", label: "New")
                KeyboardHint(keys: "⌘,", label: "Settings")
            }
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .foregroundStyle(.tertiary)
            .padding(.bottom, ThemeEngine.shared.activeTheme.spacing.lg)
        }
        .frame(width: 260)
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Button(action: { openWindow(id: "connection-form") }) {
                    Image(systemName: "plus")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: ThemeEngine.shared.activeTheme.iconSizes.extraLarge,
                            height: ThemeEngine.shared.activeTheme.iconSizes.extraLarge
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                        )
                }
                .buttonStyle(.plain)
                .help("New Connection (⌘N)")

                Button(action: { showNewGroupSheet = true }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(
                            width: ThemeEngine.shared.activeTheme.iconSizes.extraLarge,
                            height: ThemeEngine.shared.activeTheme.iconSizes.extraLarge
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .quaternaryLabelColor))
                        )
                }
                .buttonStyle(.plain)
                .help(String(localized: "New Group"))

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                        .foregroundStyle(.tertiary)

                    TextField("Search for connection...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                        .focused($focus, equals: .search)
                        .onKeyPress(.return) {
                            if let id = selectedConnectionId,
                                let connection = connections.first(where: { $0.id == id })
                            {
                                connectToDatabase(connection)
                            }
                            return .handled
                        }
                        .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
                            guard keyPress.modifiers.contains(.control) else { return .ignored }
                            moveToNextConnection()
                            focus = .connectionList
                            return .handled
                        }
                        .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
                            guard keyPress.modifiers.contains(.control) else { return .ignored }
                            moveToPreviousConnection()
                            focus = .connectionList
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveToNextConnection()
                            focus = .connectionList
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveToPreviousConnection()
                            focus = .connectionList
                            return .handled
                        }
                }
                .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.sm)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                )
            }
            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.md)
            .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.sm)

            Divider()

            // Connection list
            if filteredConnections.isEmpty {
                emptyState
            } else {
                connectionList
            }
        }
        .frame(minWidth: 350)
        .contentShape(Rectangle())
        .contextMenu { newConnectionContextMenu }
    }

    @ViewBuilder
    private var newConnectionContextMenu: some View {
        Button(action: { openWindow(id: "connection-form") }) {
            Label("New Connection...", systemImage: "plus")
        }
    }

    // MARK: - Connection List

    /// Connection list that behaves like native NSTableView:
    /// - Single click: selects row (handled by List's selection binding)
    /// - Double click: connects to database (via simultaneousGesture in ConnectionRow)
    /// - Return key: connects to selected row
    /// - Arrow keys: native keyboard navigation
    private var connectionList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedConnectionId) {
                ForEach(ungroupedConnections) { connection in
                    connectionRow(for: connection)
                }
                .onMove { from, to in
                    guard searchText.isEmpty else { return }
                    moveUngroupedConnections(from: from, to: to)
                }

                ForEach(activeGroups) { group in
                    Section {
                        if !collapsedGroupIds.contains(group.id) {
                            ForEach(connections(in: group)) { connection in
                                connectionRow(for: connection)
                            }
                        }
                    } header: {
                        groupHeader(for: group)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .connectionList)
            .environment(\.defaultMinListRowHeight, 44)
            .onKeyPress(.return) {
                if let id = selectedConnectionId,
                    let connection = connections.first(where: { $0.id == id })
                {
                    connectToDatabase(connection)
                }
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                moveToNextConnection()
                scrollToSelection(proxy)
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                moveToPreviousConnection()
                scrollToSelection(proxy)
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "h"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                collapseSelectedGroup()
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "l"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                expandSelectedGroup()
                return .handled
            }
        }
    }

    private func connectionRow(for connection: DatabaseConnection) -> some View {
        ConnectionRow(
            connection: connection,
            onConnect: { connectToDatabase(connection) },
            onEdit: {
                openWindow(id: "connection-form", value: connection.id as UUID?)
                focusConnectionFormWindow()
            },
            onDuplicate: {
                duplicateConnection(connection)
            },
            onCopyURL: {
                let pw = ConnectionStorage.shared.loadPassword(for: connection.id)
                let sshPw = ConnectionStorage.shared.loadSSHPassword(for: connection.id)
                let url = ConnectionURLFormatter.format(connection, password: pw, sshPassword: sshPw)
                ClipboardService.shared.writeText(url)
            },
            onDelete: {
                connectionToDelete = connection
                showDeleteConfirmation = true
            }
        )
        .tag(connection.id)
        .listRowInsets(ThemeEngine.shared.activeTheme.spacing.listRowInsets.swiftUI)
        .listRowSeparator(.hidden)
    }

    private func groupHeader(for group: ConnectionGroup) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                if collapsedGroupIds.contains(group.id) {
                    collapsedGroupIds.remove(group.id)
                } else {
                    collapsedGroupIds.insert(group.id)
                }
                UserDefaults.standard.set(
                    Array(collapsedGroupIds.map(\.uuidString)),
                    forKey: "com.TablePro.collapsedGroupIds"
                )
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: collapsedGroupIds.contains(group.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                if !group.color.isDefault {
                    Circle()
                        .fill(group.color.color)
                        .frame(width: 8, height: 8)
                }

                Text(group.name)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("\(connections(in: group).count)")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny))
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(group.name), \(collapsedGroupIds.contains(group.id) ? "expand" : "collapse")"))
        .contextMenu {
            Button {
                renameGroup(group)
            } label: {
                Label(String(localized: "Rename"), systemImage: "pencil")
            }

            Menu(String(localized: "Change Color")) {
                ForEach(ConnectionColor.allCases) { color in
                    Button {
                        var updated = group
                        updated.color = color
                        groupStorage.updateGroup(updated)
                        groups = groupStorage.loadGroups()
                    } label: {
                        HStack {
                            if color != .none {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(color.color)
                            }
                            Text(color.displayName)
                            if group.color == color {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                deleteGroup(group)
            } label: {
                Label(String(localized: "Delete Group"), systemImage: "trash")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.huge))
                .foregroundStyle(.tertiary)

            if searchText.isEmpty {
                Text("No Connections")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.title3, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Create a connection to get started")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    .foregroundStyle(.tertiary)

                Button(action: { openWindow(id: "connection-form") }) {
                    Label("New Connection", systemImage: "plus")
                }
                .controlSize(.large)
                .padding(.top, ThemeEngine.shared.activeTheme.spacing.xxs)
            } else {
                Text("No Matching Connections")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.title3, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("Try a different search term")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func loadConnections() {
        let saved = storage.loadConnections()
        if saved.isEmpty {
            connections = DatabaseConnection.sampleConnections
            storage.saveConnections(connections)
        } else {
            connections = saved
        }
        loadGroups()
    }

    private func connectToDatabase(_ connection: DatabaseConnection) {
        // Open main window first, then connect in background
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                if case PluginError.pluginNotInstalled = error {
                    Self.logger.info("Plugin not installed for \(connection.type.rawValue), prompting install")
                    handleMissingPlugin(connection: connection)
                } else {
                    Self.logger.error(
                        "Failed to connect: \(error.localizedDescription, privacy: .public)")
                    handleConnectionFailure(error: error)
                }
            }
        }
    }

    private func handleConnectionFailure(error: Error) {
        NSApplication.shared.closeWindows(withId: "main")
        openWindow(id: "welcome")

        AlertHelper.showErrorSheet(
            title: String(localized: "Connection Failed"),
            message: error.localizedDescription,
            window: nil
        )
    }

    private func handleMissingPlugin(connection: DatabaseConnection) {
        NSApplication.shared.closeWindows(withId: "main")
        openWindow(id: "welcome")
        pluginInstallConnection = connection
    }

    private func connectAfterInstall(_ connection: DatabaseConnection) {
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                Self.logger.error(
                    "Failed to connect after plugin install: \(error.localizedDescription, privacy: .public)")
                handleConnectionFailure(error: error)
            }
        }
    }

    private func deleteConnection(_ connection: DatabaseConnection) {
        connections.removeAll { $0.id == connection.id }
        storage.deleteConnection(connection)
        storage.saveConnections(connections)
    }

    private func duplicateConnection(_ connection: DatabaseConnection) {
        // Create duplicate with new UUID and copy passwords
        let duplicate = storage.duplicateConnection(connection)

        // Refresh connections list
        loadConnections()

        // Open edit form for the duplicate so user can rename
        openWindow(id: "connection-form", value: duplicate.id as UUID?)
        focusConnectionFormWindow()
    }

    private func loadGroups() {
        groups = groupStorage.loadGroups()
    }

    private func deleteGroup(_ group: ConnectionGroup) {
        for i in connections.indices where connections[i].groupId == group.id {
            connections[i].groupId = nil
        }
        storage.saveConnections(connections)
        groupStorage.deleteGroup(group)
        groups = groupStorage.loadGroups()
    }

    private func renameGroup(_ group: ConnectionGroup) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Group")
        alert.informativeText = String(localized: "Enter a new name for the group.")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.stringValue = group.name
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty else { return }
            let isDuplicate = groups.contains {
                $0.id != group.id && $0.name.lowercased() == newName.lowercased()
            }
            guard !isDuplicate else { return }
            var updated = group
            updated.name = newName
            groupStorage.updateGroup(updated)
            groups = groupStorage.loadGroups()
        }
    }

    private func moveToNextConnection() {
        let visible = flatVisibleConnections
        guard !visible.isEmpty else { return }
        guard let currentId = selectedConnectionId,
              let index = visible.firstIndex(where: { $0.id == currentId }) else {
            selectedConnectionId = visible.first?.id
            return
        }
        let next = min(index + 1, visible.count - 1)
        selectedConnectionId = visible[next].id
    }

    private func moveToPreviousConnection() {
        let visible = flatVisibleConnections
        guard !visible.isEmpty else { return }
        guard let currentId = selectedConnectionId,
              let index = visible.firstIndex(where: { $0.id == currentId }) else {
            selectedConnectionId = visible.last?.id
            return
        }
        let prev = max(index - 1, 0)
        selectedConnectionId = visible[prev].id
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let id = selectedConnectionId {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func collapseSelectedGroup() {
        guard let id = selectedConnectionId,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              !collapsedGroupIds.contains(groupId) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedGroupIds.insert(groupId)
            // Keep selectedConnectionId so Ctrl+L can derive the groupId to expand.
            // The List won't show a highlight for the hidden row.
            UserDefaults.standard.set(
                Array(collapsedGroupIds.map(\.uuidString)),
                forKey: "com.TablePro.collapsedGroupIds"
            )
        }
    }

    private func expandSelectedGroup() {
        guard let id = selectedConnectionId,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              collapsedGroupIds.contains(groupId) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedGroupIds.remove(groupId)
            UserDefaults.standard.set(
                Array(collapsedGroupIds.map(\.uuidString)),
                forKey: "com.TablePro.collapsedGroupIds"
            )
        }
    }

    private func moveUngroupedConnections(from source: IndexSet, to destination: Int) {
        let ungroupedIndices = connections.indices.filter { connections[$0].groupId == nil }

        let globalSource = IndexSet(source.map { ungroupedIndices[$0] })
        let globalDestination: Int
        if destination < ungroupedIndices.count {
            globalDestination = ungroupedIndices[destination]
        } else if let last = ungroupedIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        connections.move(fromOffsets: globalSource, toOffset: globalDestination)
        storage.saveConnections(connections)
    }

    /// Focus the connection form window as soon as it's available
    private func focusConnectionFormWindow() {
        // Poll rapidly until window is found (much faster than fixed delay)
        func attemptFocus(remainingAttempts: Int = 10) {
            for window in NSApp.windows {
                if window.identifier?.rawValue.contains("connection-form") == true
                    || window.title == "Connection"
                {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
            }
            // Window not found yet, try again in 20ms
            if remainingAttempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    attemptFocus(remainingAttempts: remainingAttempts - 1)
                }
            }
        }
        // Start immediately on next run loop
        DispatchQueue.main.async {
            attemptFocus()
        }
    }
}

// MARK: - ConnectionRow

private struct ConnectionRow: View {
    let connection: DatabaseConnection
    var onConnect: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onCopyURL: (() -> Void)?
    var onDelete: (() -> Void)?

    private var displayTag: ConnectionTag? {
        guard let tagId = connection.tagId else { return nil }
        return TagStorage.shared.tag(for: tagId)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Database type icon
            connection.type.iconImage
                .renderingMode(.template)
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.medium))
                .foregroundStyle(connection.displayColor)
                .frame(
                    width: ThemeEngine.shared.activeTheme.iconSizes.medium, height: ThemeEngine.shared.activeTheme.iconSizes.medium)

            // Connection info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))
                        .foregroundStyle(.primary)

                    // Tag (single)
                    if let tag = displayTag {
                        Text(tag.name)
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny))
                            .foregroundStyle(tag.color.color)
                            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.xxs)
                            .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxxs)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    tag.color.color.opacity(0.15)))
                    }
                }

                Text(connectionSubtitle)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxs)
        .contentShape(Rectangle())
        .overlay(
            DoubleClickView { onConnect?() }
        )
        .contextMenu {
            if let onConnect = onConnect {
                Button(action: onConnect) {
                    Label("Connect", systemImage: "play.fill")
                }
                Divider()
            }

            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
            }

            if let onDuplicate = onDuplicate {
                Button(action: onDuplicate) {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
            }

            if let onCopyURL = onCopyURL {
                Button(action: onCopyURL) {
                    Label("Copy as URL", systemImage: "link")
                }
            }

            if let onDelete = onDelete {
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var connectionSubtitle: String {
        if connection.sshConfig.enabled {
            return "SSH : \(connection.sshConfig.username)@\(connection.sshConfig.host)"
        }
        if connection.host.isEmpty {
            return connection.database.isEmpty ? connection.type.rawValue : connection.database
        }
        return connection.host
    }
}

// MARK: - EnvironmentBadge

private struct EnvironmentBadge: View {
    let connection: DatabaseConnection

    private var environment: ConnectionEnvironment {
        if connection.sshConfig.enabled {
            return .ssh
        }
        if connection.host.contains("prod") || connection.name.lowercased().contains("prod") {
            return .production
        }
        if connection.host.contains("staging") || connection.name.lowercased().contains("staging") {
            return .staging
        }
        return .local
    }

    var body: some View {
        Text("(\(environment.rawValue.lowercased()))")
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .foregroundStyle(environment.badgeColor)
    }
}

// MARK: - WelcomeButtonStyle

private struct WelcomeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
            .foregroundStyle(.primary)
            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.md)
            .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        Color(
                            nsColor: configuration.isPressed
                                ? .controlBackgroundColor : .quaternaryLabelColor))
            )
    }
}

// MARK: - KeyboardHint

private struct KeyboardHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.caption, design: .monospaced))
                .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.xxs + 1)
                .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                )
            Text(label)
        }
    }
}

// MARK: - ConnectionEnvironment Extension

private extension ConnectionEnvironment {
    var badgeColor: Color {
        switch self {
        case .local:
            return Color(nsColor: .systemGreen)
        case .ssh:
            return Color(nsColor: .systemBlue)
        case .staging:
            return Color(nsColor: .systemOrange)
        case .production:
            return Color(nsColor: .systemRed)
        }
    }
}

// MARK: - DoubleClickView

private struct DoubleClickView: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PassThroughDoubleClickView)?.onDoubleClick = onDoubleClick
    }
}

private class PassThroughDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        // Always forward to next responder for List selection
        super.mouseDown(with: event)
    }
}

// MARK: - Preview

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}
