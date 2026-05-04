//
//  WelcomeWindowView.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeWindowView: View {
    private enum FocusField {
        case search
        case connectionList
    }

    @State var vm = WelcomeViewModel()
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
        .background(VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow))
        .ignoresSafeArea()
        .onAppear {
            vm.setUp()
            focus = .search
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
            WelcomeLeftPanel(
                onActivateLicense: { vm.activeSheet = .activation },
                onCreateConnection: { WindowOpener.shared.openConnectionForm() }
            )
            Divider()
            rightPanel
        }
        .transition(.opacity)
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    WelcomeToolbarButton(
                        systemImage: "plus",
                        help: String(localized: "New Connection (⌘N)"),
                        accessibilityLabel: String(localized: "New Connection")
                    ) {
                        WindowOpener.shared.openConnectionForm()
                    }

                    WelcomeToolbarButton(
                        systemImage: "folder.badge.plus",
                        help: String(localized: "New Group"),
                        accessibilityLabel: String(localized: "New Group")
                    ) {
                        vm.pendingMoveToNewGroup = []
                        vm.activeSheet = .newGroup(parentId: nil)
                    }
                }
                .padding(.trailing, 12)

                NativeSearchField(
                    text: $vm.searchText,
                    placeholder: String(localized: "Search for connection..."),
                    controlSize: .regular
                )
                .focused($focus, equals: .search)
                .onKeyPress(.return) {
                    vm.connectSelectedConnections()
                    return .handled
                }
                .onKeyPress(.escape) {
                    if !vm.searchText.isEmpty {
                        vm.searchText = ""
                    }
                    focus = .connectionList
                    return .handled
                }
                .onKeyPress(characters: .init(charactersIn: "\u{7F}\u{08}"), phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.command) else { return .ignored }
                    let toDelete = vm.selectedConnections
                    guard !toDelete.isEmpty else { return .ignored }
                    vm.connectionsToDelete = toDelete
                    vm.showDeleteConfirmation = true
                    return .handled
                }
                .onKeyPress(characters: .init(charactersIn: "jn"), phases: [.down, .repeat]) { keyPress in
                    guard keyPress.modifiers.contains(.control) else { return .ignored }
                    vm.moveToNextConnection()
                    focus = .connectionList
                    return .handled
                }
                .onKeyPress(characters: .init(charactersIn: "kp"), phases: [.down, .repeat]) { keyPress in
                    guard keyPress.modifiers.contains(.control) else { return .ignored }
                    vm.moveToPreviousConnection()
                    focus = .connectionList
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    vm.moveToNextConnection()
                    focus = .connectionList
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    vm.moveToPreviousConnection()
                    focus = .connectionList
                    return .handled
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if vm.treeItems.isEmpty && vm.filteredConnections.isEmpty {
                emptyState
            } else {
                connectionList
            }
        }
        .frame(minWidth: 350)
        .contentShape(Rectangle())
        .contextMenu { newConnectionContextMenu }
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
            .onKeyPress(.return) {
                vm.connectSelectedConnections()
                return .handled
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
            sshProfile: sshProfile,
            onConnect: { vm.connectToDatabase(connection) }
        )
        .tag(connection.id)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowSeparator(.hidden)
        .contextMenu { contextMenuContent(for: connection) }
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
        .background { DoubleClickDetector { vm.connectToLinkedConnection(linked) } }
        .listRowSeparator(.hidden)
        .contextMenu {
            Button {
                vm.connectToLinkedConnection(linked)
            } label: {
                Label(String(localized: "Connect"), systemImage: "play.fill")
            }
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

    var body: some View {
        let allConnections = !items.contains { if case .group = $0 { return true } else { return false } }
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

// MARK: - Visual Effect Background

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

// MARK: - Toolbar Button

private struct WelcomeToolbarButton: View {
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Preview

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}
