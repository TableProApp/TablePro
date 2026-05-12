//
//  WelcomeWindowView.swift
//  TablePro
//

import os
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeWindowView: View {
    private enum FocusField {
        case search
        case connectionList
    }

    @State var vm = WelcomeViewModel()
    @State private var welcomeChooserState: WelcomeChooserState?
    @State private var pendingInstallType: DatabaseType?
    @State private var pendingInstallPayload: DatabaseTypeChooserPayload?
    @State private var urlImportPresented: Bool = false
    @State private var searchFocusTrigger: Int = 0
    @FocusState private var focus: FocusField?

    var body: some View {
        ZStack {
            if vm.showOnboarding {
                OnboardingContentView {
                    withAnimation(.easeInOut(duration: 0.45)) {
                        vm.showOnboarding = false
                    }
                }
                .transition(.move(edge: .leading))
            } else {
                welcomeContent
                    .transition(.move(edge: .trailing))
            }
        }
        .ignoresSafeArea()
        .onAppear {
            vm.setUp()
            focus = .connectionList
        }
        .alert(
            vm.connectionsToDelete.count == 1
                ? String(localized: "Delete Connection")
                : String(format: String(localized: "Delete %d Connections"), vm.connectionsToDelete.count),
            isPresented: $vm.showDeleteConfirmation
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                vm.deleteSelectedConnections()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                vm.connectionsToDelete = []
            }
        } message: {
            if vm.connectionsToDelete.count == 1, let first = vm.connectionsToDelete.first {
                Text("Are you sure you want to delete \"\(first.name)\"?")
            } else {
                Text("Are you sure you want to delete \(vm.connectionsToDelete.count) connections? This cannot be undone.")
            }
        }
        .alert(
            String(localized: "Delete Group"),
            isPresented: $vm.showDeleteGroupConfirmation
        ) {
            Button(String(localized: "Delete"), role: .destructive) {
                vm.confirmDeleteGroup()
            }
            Button(String(localized: "Cancel"), role: .cancel) {
                vm.groupToDelete = nil
            }
        } message: {
            if let group = vm.groupToDelete {
                Text("Are you sure you want to delete the group \"\(group.name)\"? Connections in this group will be moved to the top level.")
            }
        }
        .sheet(item: $vm.activeSheet) { sheet in
            switch sheet {
            case .newGroup(let parentId):
                CreateGroupSheet(parentId: parentId) { name, color, pid in
                    let group = ConnectionGroup(name: name, color: color, parentId: pid)
                    GroupStorage.shared.addGroup(group)
                    vm.groups = GroupStorage.shared.loadGroups()
                    vm.expandedGroupIds.insert(group.id)
                    if let pid {
                        vm.expandedGroupIds.insert(pid)
                    }
                    if !vm.pendingMoveToNewGroup.isEmpty {
                        vm.moveConnections(vm.pendingMoveToNewGroup, toGroup: group.id)
                        vm.pendingMoveToNewGroup = []
                    }
                }
            case .activation:
                LicenseActivationSheet()
            case .importFile(let url):
                ConnectionImportSheet(fileURL: url) { count in
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        vm.showImportResult(count: count)
                    }
                }
            case .exportConnections(let conns):
                ConnectionExportOptionsSheet(connections: conns)
            case .importFromApp:
                ImportFromAppSheet { count in
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        vm.showImportResult(count: count)
                    }
                }
            case .deeplinkImport(let exportable):
                DeeplinkImportSheet(connection: exportable) {
                    vm.loadConnections()
                }
            }
        }
        .modifier(ConnectionCreationOverlays(
            chooserState: $welcomeChooserState,
            urlImportPresented: $urlImportPresented
        ))
        .onReceive(AppCommands.shared.presentDatabaseTypeChooser) { payload in
            welcomeChooserState = WelcomeChooserState(
                initialType: payload.initialType,
                onSelected: { type in
                    if PluginManager.shared.isDriverInstalled(for: type) {
                        PendingNewConnectionType.shared.set(type)
                        payload.onSelected(type)
                    } else {
                        pendingInstallPayload = payload
                        pendingInstallType = type
                    }
                }
            )
        }
        .pluginInstallPromptForType(type: $pendingInstallType) { type in
            if let payload = pendingInstallPayload {
                PendingNewConnectionType.shared.set(type)
                payload.onSelected(type)
                pendingInstallPayload = nil
            }
        }
        .pluginInstallPrompt(connection: $vm.pluginInstallConnection) { connection in
            vm.connectAfterInstall(connection)
        }
        .alert(String(localized: "Rename Group"), isPresented: $vm.showRenameGroupAlert) {
            TextField(String(localized: "Group name"), text: $vm.renameGroupName)
            Button(String(localized: "Rename")) { vm.confirmRenameGroup() }
            Button(String(localized: "Cancel"), role: .cancel) { vm.renameGroupTarget = nil }
        } message: {
            Text("Enter a new name for the group.")
        }
        .alert(
            String(localized: "Connection Failed"),
            isPresented: $vm.showConnectionError
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                vm.connectionError = nil
            }
        } message: {
            if let error = vm.connectionError {
                Text(error)
            }
        }
        .fileImporter(
            isPresented: $vm.showImportFilePanel,
            allowedContentTypes: [.tableproConnectionShare],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                vm.activeSheet = .importFile(url)
            }
        }
        .alert(
            (vm.importResultCount ?? 0) > 0
                ? String(localized: "Import Complete")
                : String(localized: "No Connections Imported"),
            isPresented: Binding(
                get: { vm.importResultCount != nil },
                set: { if !$0 { vm.importResultCount = nil } }
            )
        ) {
            Button(String(localized: "OK")) { vm.importResultCount = nil }
        } message: {
            if let count = vm.importResultCount, count > 0 {
                Text(count == 1
                    ? String(localized: "1 connection was imported.")
                    : String(format: String(localized: "%d connections were imported."), count))
            } else {
                Text(String(localized: "All selected connections were skipped."))
            }
        }
    }

    // MARK: - Layout

    private var welcomeContent: some View {
        HStack(spacing: 0) {
            WelcomeActionsPanel(
                onActivateLicense: { vm.activeSheet = .activation },
                onCreateConnection: { WindowOpener.shared.openConnectionForm() },
                onTrySample: { vm.openSampleDatabase() }
            )
            .frame(width: 240)
            .themeMaterial(.sidebar, .regularMaterial)

            Divider()

            connectionsPanel
        }
        .transition(.opacity)
    }

    // MARK: - Connections panel

    private var connectionsPanel: some View {
        VStack(spacing: 0) {
            connectionsHeader
            Divider()
            ZStack {
                if vm.treeItems.isEmpty && vm.linkedConnections.isEmpty {
                    emptyState
                } else {
                    connectionList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
        .contextMenu { newConnectionContextMenu }
        .background(findShortcut)
    }

    private var findShortcut: some View {
        Button {
            searchFocusTrigger += 1
        } label: {
            EmptyView()
        }
        .keyboardShortcut("f", modifiers: .command)
        .accessibilityHidden(true)
    }

    private var connectionsHeader: some View {
        HStack(spacing: 8) {
            Button {
                WindowOpener.shared.openConnectionForm()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(String(localized: "New Connection (⌘N)"))
            .accessibilityLabel(String(localized: "New Connection"))

            Button {
                vm.pendingMoveToNewGroup = []
                vm.activeSheet = .newGroup(parentId: nil)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(String(localized: "New Group"))
            .accessibilityLabel(String(localized: "New Group"))

            Spacer()

            NativeSearchField(
                text: $vm.searchText,
                placeholder: String(localized: "Search for connection..."),
                controlSize: .regular,
                focusTrigger: searchFocusTrigger,
                maxWidth: 240
            )
            .focused($focus, equals: .search)
            .layoutPriority(0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Connection List

    private var connectionList: some View {
        ScrollViewReader { proxy in
            List(selection: $vm.selectedConnectionIds) {
                TreeRowsView(items: vm.treeItems, parentGroupId: nil, vm: vm) { conn in
                    connectionRow(for: conn)
                }

                if !vm.linkedConnections.isEmpty, LicenseManager.shared.isFeatureAvailable(.linkedFolders) {
                    Section {
                        ForEach(vm.linkedConnections) { linked in
                            linkedConnectionRow(for: linked)
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                            Text(String(localized: "Linked"))
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .connectionList)
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenuContent(for: ids)
            } primaryAction: { ids in
                primaryAction(for: ids)
            }
            .onKeyPress(characters: .init(charactersIn: "\u{7F}\u{08}"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                let toDelete = vm.selectedConnections
                guard !toDelete.isEmpty else { return .ignored }
                vm.connectionsToDelete = toDelete
                vm.showDeleteConfirmation = true
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "a"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.command) else { return .ignored }
                vm.selectedConnectionIds = Set(vm.flatVisibleConnections.map(\.id))
                return .handled
            }
            .onKeyPress(.escape) {
                if !vm.selectedConnectionIds.isEmpty {
                    vm.selectedConnectionIds = []
                }
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.moveToNextConnection()
                scrollToSelection(proxy)
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.moveToPreviousConnection()
                scrollToSelection(proxy)
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "h"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.collapseSelectedGroup()
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "l"), phases: .down) { keyPress in
                guard keyPress.modifiers.contains(.control) else { return .ignored }
                vm.expandSelectedGroup()
                return .handled
            }
        }
    }

    // MARK: - Rows

    func connectionRow(for connection: DatabaseConnection) -> some View {
        let sshProfile = connection.sshProfileId.flatMap { SSHProfileStorage.shared.profile(for: $0) }
        return WelcomeConnectionRow(
            connection: connection,
            sshProfile: sshProfile
        )
        .tag(connection.id)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowSeparator(.hidden)
    }

    private func linkedConnectionRow(for linked: LinkedConnection) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                DatabaseType(rawValue: linked.connection.type).iconImage
                    .frame(width: 28, height: 28)
                Image(systemName: "folder.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(linked.connection.name)
                    .lineLimit(1)
                Text("\(linked.connection.host):\(linked.connection.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .tag(linked.id)
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .contentShape(Rectangle())
        .listRowSeparator(.hidden)
    }

    func primaryAction(for ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for connection in vm.connections where ids.contains(connection.id) {
            vm.connectToDatabase(connection)
        }
        for linked in vm.linkedConnections where ids.contains(linked.id) {
            vm.connectToLinkedConnection(linked)
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if vm.searchText.isEmpty {
            EmptyStateView(
                icon: "cylinder.split.1x2",
                title: String(localized: "No Connections"),
                description: String(localized: "Try the sample database, or click + above to add your own."),
                actionTitle: String(localized: "Try Sample Database"),
                action: { vm.openSampleDatabase() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                icon: "magnifyingglass",
                title: String(localized: "No Matching Connections"),
                description: String(localized: "Try a different search term.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let id = vm.selectedConnectionIds.first {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

// MARK: - Tree Rendering

private struct TreeRowsView<ConnectionContent: View>: View {
    let items: [ConnectionGroupTreeNode]
    let parentGroupId: UUID?
    var vm: WelcomeViewModel
    let connectionRowBuilder: (DatabaseConnection) -> ConnectionContent

    private var hasGroups: Bool {
        items.contains { node in
            if case .group = node { return true }
            return false
        }
    }

    var body: some View {
        let allConnections = !hasGroups
        ForEach(items) { item in
            switch item {
            case .connection(let conn):
                connectionRowBuilder(conn)
            case .group(let group, let children):
                DisclosureGroup(isExpanded: expandedBinding(for: group.id)) {
                    TreeRowsView(
                        items: children,
                        parentGroupId: group.id,
                        vm: vm,
                        connectionRowBuilder: connectionRowBuilder
                    )
                } label: {
                    groupLabel(for: group)
                }
            }
        }
        .onMove(perform: allConnections ? { from, to in
            guard vm.searchText.isEmpty else { return }
            if let parentGroupId, let group = vm.groups.first(where: { $0.id == parentGroupId }) {
                vm.moveGroupedConnections(in: group, from: from, to: to)
            } else {
                vm.moveUngroupedConnections(from: from, to: to)
            }
        } : nil)
    }

    private func expandedBinding(for groupId: UUID) -> Binding<Bool> {
        Binding(
            get: { vm.expandedGroupIds.contains(groupId) },
            set: { expanded in
                if expanded {
                    vm.expandedGroupIds.insert(groupId)
                } else {
                    vm.expandedGroupIds.remove(groupId)
                }
            }
        )
    }

    private func groupLabel(for group: ConnectionGroup) -> some View {
        HStack(spacing: 6) {
            if !group.color.isDefault {
                Circle()
                    .fill(group.color.color)
                    .frame(width: 8, height: 8)
            }

            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(vm.connectionCountByGroup[group.id] ?? 0)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            groupContextMenu(for: group)
        }
    }

    @ViewBuilder
    private func groupContextMenu(for group: ConnectionGroup) -> some View {
        Button {
            vm.beginRenameGroup(group)
        } label: {
            Label(String(localized: "Rename"), systemImage: "pencil")
        }

        let currentGroupDepth = vm.depthByGroup[group.id] ?? 0
        Button {
            vm.createSubgroup(under: group.id)
        } label: {
            Label(String(localized: "New Subgroup"), systemImage: "folder.badge.plus")
        }
        .disabled(currentGroupDepth >= 3)

        Menu(String(localized: "Change Color")) {
            ForEach(ConnectionColor.allCases) { color in
                Button {
                    vm.updateGroupColor(group, color: color)
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

        if vm.groups.count > 1 {
            Menu(String(localized: "Move Group to...")) {
                Button {
                    vm.moveGroup(group, toParent: nil)
                } label: {
                    HStack {
                        Text("Top Level")
                        if group.parentId == nil {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(group.parentId == nil)

                Divider()

                ForEach(vm.groups.filter({ $0.id != group.id })) { targetGroup in
                    let wouldCircle = wouldCreateCircle(
                        movingGroupId: group.id,
                        toParentId: targetGroup.id,
                        groups: vm.groups
                    )
                    let targetDepth = vm.depthByGroup[targetGroup.id] ?? 0
                    let subtreeDepth = vm.maxDescendantDepthByGroup[group.id] ?? 0
                    let wouldExceedDepth = targetDepth + 1 + subtreeDepth > 3

                    Button {
                        vm.moveGroup(group, toParent: targetGroup.id)
                    } label: {
                        HStack {
                            if !targetGroup.color.isDefault {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(targetGroup.color.color)
                            }
                            Text(targetGroup.name)
                            if group.parentId == targetGroup.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(wouldCircle || wouldExceedDepth || group.parentId == targetGroup.id)
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            vm.requestDeleteGroup(group)
        } label: {
            Label(String(localized: "Delete Group"), systemImage: "trash")
        }
    }
}

// MARK: - Welcome Chooser State

private struct WelcomeChooserState: Identifiable {
    let id = UUID()
    let initialType: DatabaseType?
    let onSelected: (DatabaseType) -> Void
}

// MARK: - Connection Creation Overlays

private struct ConnectionCreationOverlays: ViewModifier {
    @Binding var chooserState: WelcomeChooserState?
    @Binding var urlImportPresented: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $chooserState) { state in
                DatabaseTypeChooserSheet(
                    initialType: state.initialType,
                    onSelected: { type in
                        state.onSelected(type)
                        chooserState = nil
                    },
                    onImportFromURL: {
                        chooserState = nil
                        urlImportPresented = true
                    },
                    onCancel: { chooserState = nil }
                )
            }
            .sheet(isPresented: $urlImportPresented) {
                ImportFromURLSheet(
                    onImported: { parsed in
                        urlImportPresented = false
                        WindowOpener.shared.openConnectionFormFromURL(parsed)
                    },
                    onCancel: {
                        urlImportPresented = false
                    }
                )
            }
    }
}

// MARK: - Preview

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}
