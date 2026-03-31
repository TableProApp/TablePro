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
    @Environment(\.openWindow) var openWindow

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
        .background(.background)
        .ignoresSafeArea()
        .frame(minWidth: 650, minHeight: 400)
        .onAppear {
            vm.setUp(openWindow: openWindow)
            focus = .search
        }
        .confirmationDialog(
            vm.connectionsToDelete.count == 1
                ? String(localized: "Delete Connection")
                : String(localized: "Delete \(vm.connectionsToDelete.count) Connections"),
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
                        vm.showImportResultAlert(count: count)
                    }
                }
            case .exportConnections(let conns):
                ConnectionExportOptionsSheet(connections: conns)
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
    }

    // MARK: - Layout

    private var welcomeContent: some View {
        HStack(spacing: 0) {
            WelcomeLeftPanel(
                onActivateLicense: { vm.activeSheet = .activation },
                onCreateConnection: { openWindow(id: "connection-form") }
            )
            Divider()
            rightPanel
        }
        .transition(.opacity)
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(spacing: 0) {
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

                Button(action: { vm.pendingMoveToNewGroup = []; vm.activeSheet = .newGroup(parentId: nil) }) {
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

                    TextField("Search for connection...", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
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
                treeRows(vm.treeItems)

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
            .environment(\.defaultMinListRowHeight, 44)
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

    // MARK: - Tree Rendering

    private func treeRows(_ items: [ConnectionGroupTreeNode], parentGroupId: UUID? = nil) -> AnyView {
        let allConnections = !items.contains { if case .group = $0 { return true } else { return false } }
        return AnyView(
            ForEach(items) { item in
                switch item {
                case .connection(let conn):
                    connectionRow(for: conn)
                case .group(let group, let children):
                    DisclosureGroup(isExpanded: expandedBinding(for: group.id)) {
                        treeRows(children, parentGroupId: group.id)
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
        )
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

    // MARK: - Rows

    private func connectionRow(for connection: DatabaseConnection) -> some View {
        let sshProfile = connection.sshProfileId.flatMap { SSHProfileStorage.shared.profile(for: $0) }
        return WelcomeConnectionRow(
            connection: connection,
            sshProfile: sshProfile,
            onConnect: { vm.connectToDatabase(connection) }
        )
        .tag(connection.id)
        .listRowInsets(ThemeEngine.shared.activeTheme.spacing.listRowInsets.swiftUI)
        .listRowSeparator(.hidden)
        .contextMenu { contextMenuContent(for: connection) }
    }

    private func linkedConnectionRow(for linked: LinkedConnection) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                DatabaseType(rawValue: linked.connection.type).iconImage
                    .frame(width: 28, height: 28)
                Image(systemName: "folder.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(linked.connection.name)
                    .lineLimit(1)
                Text("\(linked.connection.host):\(String(linked.connection.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxs)
        .listRowInsets(ThemeEngine.shared.activeTheme.spacing.listRowInsets.swiftUI)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            vm.connectToLinkedConnection(linked)
        })
        .listRowSeparator(.hidden)
        .contextMenu {
            Button {
                vm.connectToLinkedConnection(linked)
            } label: {
                Label(String(localized: "Connect"), systemImage: "play.fill")
            }
        }
    }

    // MARK: - Group Label

    private func groupLabel(for group: ConnectionGroup) -> some View {
        HStack(spacing: 6) {
            if !group.color.isDefault {
                Circle()
                    .fill(group.color.color)
                    .frame(width: 8, height: 8)
            }

            Text(group.name)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("\(connectionCount(in: group.id, connections: vm.connections, groups: vm.groups))")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            groupContextMenu(for: group)
        }
    }

    // MARK: - Group Context Menu

    @ViewBuilder
    private func groupContextMenu(for group: ConnectionGroup) -> some View {
        Button {
            vm.beginRenameGroup(group)
        } label: {
            Label(String(localized: "Rename"), systemImage: "pencil")
        }

        let currentGroupDepth = depthOf(groupId: group.id, groups: vm.groups)
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
                    let targetDepth = depthOf(groupId: targetGroup.id, groups: vm.groups)
                    let subtreeDepth = maxDescendantDepth(groupId: group.id, groups: vm.groups)
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
            vm.deleteGroup(group)
        } label: {
            Label(String(localized: "Delete Group"), systemImage: "trash")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "cylinder.split.1x2")
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.huge))
                .foregroundStyle(.tertiary)

            if vm.searchText.isEmpty {
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

    // MARK: - Helpers

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let id = vm.selectedConnectionIds.first {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

// MARK: - Preview

#Preview("Welcome Window") {
    WelcomeWindowView()
        .frame(width: 700, height: 450)
}
