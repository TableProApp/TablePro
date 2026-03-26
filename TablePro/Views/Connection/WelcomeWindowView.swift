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
    @State private var connectionsToDelete: [DatabaseConnection] = []
    @State private var showDeleteConfirmation = false
    @State private var selectedConnectionIds: Set<UUID> = []
    @FocusState private var focus: FocusField?
    @State private var showOnboarding = !AppSettingsStorage.shared.hasCompletedOnboarding()
    @State private var groups: [ConnectionGroup] = []
    @State private var collapsedGroupIds: Set<UUID> = {
        let strings = UserDefaults.standard.stringArray(forKey: "com.TablePro.collapsedGroupIds") ?? []
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }()
    @State private var showNewGroupSheet = false
    @State private var pendingMoveToNewGroup: [DatabaseConnection] = []
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

    private var selectedConnections: [DatabaseConnection] {
        connections.filter { selectedConnectionIds.contains($0.id) }
    }

    private var isMultipleSelection: Bool {
        selectedConnectionIds.count > 1
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
            focus = .search
        }
        .confirmationDialog(
            connectionsToDelete.count == 1
                ? String(localized: "Delete Connection")
                : String(localized: "Delete \(connectionsToDelete.count) Connections"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                deleteSelectedConnections()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                connectionsToDelete = []
            }
        } message: {
            if connectionsToDelete.count == 1, let first = connectionsToDelete.first {
                Text("Are you sure you want to delete \"\(first.name)\"?")
            } else {
                Text("Are you sure you want to delete \(connectionsToDelete.count) connections? This cannot be undone.")
            }
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
                if !pendingMoveToNewGroup.isEmpty {
                    moveConnections(pendingMoveToNewGroup, toGroup: group.id)
                    pendingMoveToNewGroup = []
                }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SyncStatusIndicator()
                    KeyboardHint(keys: "↵", label: "Connect")
                    KeyboardHint(keys: "⌘N", label: "New")
                    KeyboardHint(keys: "⌘,", label: "Settings")
                }
                HStack(spacing: 8) {
                    SyncStatusIndicator()
                    KeyboardHint(keys: "↵", label: "Connect")
                    KeyboardHint(keys: "⌘N", label: "New")
                    KeyboardHint(keys: "⌘,", label: nil)
                }
            }
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.sm)
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

                Button(action: { pendingMoveToNewGroup = []; showNewGroupSheet = true }) {
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
                            connectSelectedConnections()
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            if !searchText.isEmpty {
                                searchText = ""
                            }
                            focus = .connectionList
                            return .handled
                        }
                        .onKeyPress(characters: .init(charactersIn: "\u{7F}\u{08}"), phases: .down) { keyPress in
                            guard keyPress.modifiers.contains(.command) else { return .ignored }
                            let toDelete = selectedConnections
                            guard !toDelete.isEmpty else { return .ignored }
                            connectionsToDelete = toDelete
                            showDeleteConfirmation = true
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
            List(selection: $selectedConnectionIds) {
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
                            .onMove { from, to in
                                guard searchText.isEmpty else { return }
                                moveGroupedConnections(in: group, from: from, to: to)
                            }
                        }
                    } header: {
                        groupHeader(for: group)
                    }
                }
                .onMove { from, to in
                    guard searchText.isEmpty else { return }
                    moveGroups(from: from, to: to)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .connectionList)
            .environment(\.defaultMinListRowHeight, 44)
            .onKeyPress(.return) {
                connectSelectedConnections()
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "\u{7F}\u{08}"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                let toDelete = selectedConnections
                guard !toDelete.isEmpty else { return .ignored }
                connectionsToDelete = toDelete
                showDeleteConfirmation = true
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "a"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                selectedConnectionIds = Set(flatVisibleConnections.map(\.id))
                return .handled
            }
            .onKeyPress(.escape) {
                if !selectedConnectionIds.isEmpty {
                    selectedConnectionIds = []
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
        let sshProfile = connection.sshProfileId.flatMap { SSHProfileStorage.shared.profile(for: $0) }
        return ConnectionRow(connection: connection, sshProfile: sshProfile, onConnect: { connectToDatabase(connection) })
            .tag(connection.id)
            .listRowInsets(ThemeEngine.shared.activeTheme.spacing.listRowInsets.swiftUI)
            .listRowSeparator(.hidden)
            .contextMenu { contextMenuContent(for: connection) }
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

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuContent(for connection: DatabaseConnection) -> some View {
        if isMultipleSelection, selectedConnectionIds.contains(connection.id) {
            Button { connectSelectedConnections() } label: {
                Label(
                    String(localized: "Connect \(selectedConnectionIds.count) Connections"),
                    systemImage: "play.fill"
                )
            }

            Divider()

            moveToGroupMenu(for: selectedConnections)

            let validGroupIds = Set(groups.map(\.id))
            if selectedConnections.contains(where: { $0.groupId.map { validGroupIds.contains($0) } ?? false }) {
                Button { removeFromGroup(selectedConnections) } label: {
                    Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
                }
            }

            Divider()

            Button(role: .destructive) {
                connectionsToDelete = selectedConnections
                showDeleteConfirmation = true
            } label: {
                Label(
                    String(localized: "Delete \(selectedConnectionIds.count) Connections"),
                    systemImage: "trash"
                )
            }
        } else {
            Button { connectToDatabase(connection) } label: {
                Label(String(localized: "Connect"), systemImage: "play.fill")
            }

            Divider()

            Button {
                openWindow(id: "connection-form", value: connection.id as UUID?)
                focusConnectionFormWindow()
            } label: {
                Label(String(localized: "Edit"), systemImage: "pencil")
            }

            Button { duplicateConnection(connection) } label: {
                Label(String(localized: "Duplicate"), systemImage: "doc.on.doc")
            }

            Button {
                let pw = ConnectionStorage.shared.loadPassword(for: connection.id)
                let sshPw: String?
                let sshProfile: SSHProfile?
                if let profileId = connection.sshProfileId {
                    sshPw = SSHProfileStorage.shared.loadSSHPassword(for: profileId)
                    sshProfile = SSHProfileStorage.shared.profile(for: profileId)
                } else {
                    sshPw = ConnectionStorage.shared.loadSSHPassword(for: connection.id)
                    sshProfile = nil
                }
                let url = ConnectionURLFormatter.format(
                    connection,
                    password: pw,
                    sshPassword: sshPw,
                    sshProfile: sshProfile
                )
                ClipboardService.shared.writeText(url)
            } label: {
                Label(String(localized: "Copy as URL"), systemImage: "link")
            }

            Divider()

            moveToGroupMenu(for: [connection])

            if let groupId = connection.groupId, groups.contains(where: { $0.id == groupId }) {
                Button { removeFromGroup([connection]) } label: {
                    Label(String(localized: "Remove from Group"), systemImage: "folder.badge.minus")
                }
            }

            Divider()

            Button(role: .destructive) {
                connectionsToDelete = [connection]
                showDeleteConfirmation = true
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func moveToGroupMenu(for targets: [DatabaseConnection]) -> some View {
        let isSingle = targets.count == 1
        let currentGroupId = isSingle ? targets.first?.groupId : nil
        Menu(String(localized: "Move to Group")) {
            ForEach(groups) { group in
                Button {
                    moveConnections(targets, toGroup: group.id)
                } label: {
                    HStack {
                        if !group.color.isDefault {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(group.color.color)
                        }
                        Text(group.name)
                        if currentGroupId == group.id {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(currentGroupId == group.id)
            }

            if !groups.isEmpty {
                Divider()
            }

            Button {
                pendingMoveToNewGroup = targets
                showNewGroupSheet = true
            } label: {
                Label(String(localized: "New Group..."), systemImage: "folder.badge.plus")
            }
        }
    }

    private func moveConnections(_ targets: [DatabaseConnection], toGroup groupId: UUID) {
        let ids = Set(targets.map(\.id))
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = groupId
        }
        storage.saveConnections(connections)
    }

    private func removeFromGroup(_ targets: [DatabaseConnection]) {
        let ids = Set(targets.map(\.id))
        for i in connections.indices where ids.contains(connections[i].id) {
            connections[i].groupId = nil
        }
        storage.saveConnections(connections)
    }

    // MARK: - Actions

    private func loadConnections() {
        connections = storage.loadConnections()
        loadGroups()
    }

    private func connectToDatabase(_ connection: DatabaseConnection) {
        // Set pendingConnectionId so AppDelegate assigns the correct per-connection tabbingIdentifier
        WindowOpener.shared.pendingConnectionId = connection.id
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
        WindowOpener.shared.pendingConnectionId = connection.id
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

    private func connectSelectedConnections() {
        for connection in selectedConnections {
            connectToDatabase(connection)
        }
    }

    private func deleteSelectedConnections() {
        let idsToDelete = Set(connectionsToDelete.map(\.id))
        storage.deleteConnections(connectionsToDelete)
        connections.removeAll { idsToDelete.contains($0.id) }
        selectedConnectionIds.subtract(idsToDelete)
        connectionsToDelete = []
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
        let anchorId = visible.last(where: { selectedConnectionIds.contains($0.id) })?.id
        guard let anchorId,
              let index = visible.firstIndex(where: { $0.id == anchorId }) else {
            selectedConnectionIds = Set([visible[0].id])
            return
        }
        let next = min(index + 1, visible.count - 1)
        selectedConnectionIds = [visible[next].id]
    }

    private func moveToPreviousConnection() {
        let visible = flatVisibleConnections
        guard !visible.isEmpty else { return }
        let anchorId = visible.first(where: { selectedConnectionIds.contains($0.id) })?.id
        guard let anchorId,
              let index = visible.firstIndex(where: { $0.id == anchorId }) else {
            selectedConnectionIds = Set([visible[visible.count - 1].id])
            return
        }
        let prev = max(index - 1, 0)
        selectedConnectionIds = [visible[prev].id]
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let id = selectedConnectionIds.first {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func collapseSelectedGroup() {
        guard let id = selectedConnectionIds.first,
              let connection = connections.first(where: { $0.id == id }),
              let groupId = connection.groupId,
              !collapsedGroupIds.contains(groupId) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            collapsedGroupIds.insert(groupId)
            // Keep selectedConnectionIds so Ctrl+L can derive the groupId to expand.
            // The List won't show a highlight for the hidden row.
            UserDefaults.standard.set(
                Array(collapsedGroupIds.map(\.uuidString)),
                forKey: "com.TablePro.collapsedGroupIds"
            )
        }
    }

    private func expandSelectedGroup() {
        guard let id = selectedConnectionIds.first,
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
        let validGroupIds = Set(groups.map(\.id))
        let ungroupedIndices = connections.indices.filter { index in
            guard let groupId = connections[index].groupId else { return true }
            return !validGroupIds.contains(groupId)
        }

        guard source.allSatisfy({ $0 < ungroupedIndices.count }),
              destination <= ungroupedIndices.count else { return }

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

    private func moveGroupedConnections(in group: ConnectionGroup, from source: IndexSet, to destination: Int) {
        let groupIndices = connections.indices.filter { connections[$0].groupId == group.id }

        guard source.allSatisfy({ $0 < groupIndices.count }),
              destination <= groupIndices.count else { return }

        let globalSource = IndexSet(source.map { groupIndices[$0] })
        let globalDestination: Int
        if destination < groupIndices.count {
            globalDestination = groupIndices[destination]
        } else if let last = groupIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        connections.move(fromOffsets: globalSource, toOffset: globalDestination)
        storage.saveConnections(connections)
    }

    private func moveGroups(from source: IndexSet, to destination: Int) {
        let active = activeGroups
        let activeGroupIndices = active.compactMap { activeGroup in
            groups.firstIndex(where: { $0.id == activeGroup.id })
        }

        guard source.allSatisfy({ $0 < activeGroupIndices.count }),
              destination <= activeGroupIndices.count else { return }

        let globalSource = IndexSet(source.map { activeGroupIndices[$0] })
        let globalDestination: Int
        if destination < activeGroupIndices.count {
            globalDestination = activeGroupIndices[destination]
        } else if let last = activeGroupIndices.last {
            globalDestination = last + 1
        } else {
            globalDestination = 0
        }

        groups.move(fromOffsets: globalSource, toOffset: globalDestination)
        groupStorage.saveGroups(groups)
    }

    /// Focus the connection form window as soon as it's available
    private func focusConnectionFormWindow() {
        Task { @MainActor in
            for _ in 0..<10 {
                for window in NSApp.windows where
                    window.identifier?.rawValue == "connection-form" {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

// MARK: - ConnectionRow

private struct ConnectionRow: View {
    let connection: DatabaseConnection
    let sshProfile: SSHProfile?
    var onConnect: (() -> Void)?

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
                    width: ThemeEngine.shared.activeTheme.iconSizes.medium,
                    height: ThemeEngine.shared.activeTheme.iconSizes.medium
                )

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
    }

    private var connectionSubtitle: String {
        let ssh = connection.effectiveSSHConfig(profile: sshProfile)
        if ssh.enabled {
            return "SSH : \(ssh.username)@\(ssh.host)"
        }
        if connection.host.isEmpty {
            return connection.database.isEmpty ? connection.type.rawValue : connection.database
        }
        return connection.host
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
    let label: String?

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
            if let label {
                Text(label)
            }
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
