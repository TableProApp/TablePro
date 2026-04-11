//
//  ConnectionListView.swift
//  TableProMobile
//

import SwiftUI
import TableProModels
import TableProSync

struct ConnectionListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingAddConnection = false
    @State private var editingConnection: DatabaseConnection?
    @AppStorage("lastConnectionId") private var selectedConnectionIdString: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showingGroupManagement = false
    @State private var showingTagManagement = false
    @AppStorage("lastFilterTagId") private var filterTagIdString: String?
    @AppStorage("groupByGroup") private var groupByGroup = false
    @State private var editMode: EditMode = .inactive
    @State private var connectionToDelete: DatabaseConnection?

    private var showDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { connectionToDelete != nil },
            set: { if !$0 { connectionToDelete = nil } }
        )
    }

    private var selectedConnectionId: Binding<UUID?> {
        Binding(
            get: { selectedConnectionIdString.flatMap { UUID(uuidString: $0) } },
            set: { selectedConnectionIdString = $0?.uuidString }
        )
    }

    private var selectedConnectionUUID: UUID? {
        selectedConnectionIdString.flatMap { UUID(uuidString: $0) }
    }

    private var filterTagId: UUID? {
        filterTagIdString.flatMap { UUID(uuidString: $0) }
    }

    private var displayedConnections: [DatabaseConnection] {
        var result = appState.connections
        if let filterTagId {
            result = result.filter { $0.tagId == filterTagId }
        }
        return result.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var isSyncing: Bool {
        appState.syncCoordinator.status == .syncing
    }

    private var selectedConnection: DatabaseConnection? {
        guard let id = selectedConnectionUUID else { return nil }
        return appState.connections.first { $0.id == id }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationTitle("Connections")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        filterMenu
                        if filterTagId == nil && !appState.connections.isEmpty {
                            Button(editMode == .active ? "Done" : "Edit") {
                                editMode = editMode == .active ? .inactive : .active
                            }
                        }
                        Button {
                            showingAddConnection = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task {
                                await appState.syncCoordinator.sync(
                                    localConnections: appState.connections,
                                    localGroups: appState.groups,
                                    localTags: appState.tags
                                )
                            }
                        } label: {
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath.icloud")
                            }
                        }
                        .disabled(isSyncing)
                    }
                }
            .onChange(of: appState.pendingConnectionId) { _, newId in
                navigateToPendingConnection(newId)
            }
            .onChange(of: filterTagIdString) {
                editMode = .inactive
            }
            .onChange(of: groupByGroup) {
                editMode = .inactive
            }
            .onAppear {
                navigateToPendingConnection(appState.pendingConnectionId)
            }
        } detail: {
            NavigationStack {
                if let connection = selectedConnection {
                    ConnectedView(connection: connection)
                        .id(connection.id)
                } else {
                    ContentUnavailableView(
                        "Select a Connection",
                        systemImage: "server.rack",
                        description: Text("Choose a connection from the sidebar.")
                    )
                }
            }
        }
        .sheet(isPresented: $showingAddConnection) {
            ConnectionFormView { connection in
                appState.addConnection(connection)
                showingAddConnection = false
            }
        }
        .sheet(item: $editingConnection) { connection in
            ConnectionFormView(editing: connection) { updated in
                appState.updateConnection(updated)
                editingConnection = nil
            }
        }
        .sheet(isPresented: $showingGroupManagement) {
            GroupManagementView()
        }
        .sheet(isPresented: $showingTagManagement) {
            TagManagementView()
        }
    }

    @ViewBuilder
    private var connectionList: some View {
        let list = List(selection: selectedConnectionId) {
            if groupByGroup {
                groupedContent
            } else {
                ForEach(displayedConnections) { connection in
                    connectionRow(connection)
                }
                .onMove { source, destination in
                    var items = displayedConnections
                    items.move(fromOffsets: source, toOffset: destination)
                    for index in items.indices {
                        items[index].sortOrder = index
                    }
                    appState.reorderConnections(items)
                }
            }
        }
        if sizeClass == .regular {
            list.listStyle(.sidebar)
        } else {
            list.listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if appState.connections.isEmpty && !isSyncing {
            ContentUnavailableView {
                Label("No Connections", systemImage: "server.rack")
            } description: {
                Text("Add a database connection to get started.")
            } actions: {
                Button("Add Connection") {
                    showingAddConnection = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else if appState.connections.isEmpty && isSyncing {
            ProgressView("Syncing from iCloud...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            connectionList
            .overlay {
                if !appState.connections.isEmpty && displayedConnections.isEmpty {
                    ContentUnavailableView(
                        "No Matching Connections",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("No connections match the selected filter.")
                    )
                }
            }
            .environment(\.editMode, $editMode)
            .refreshable {
                await appState.syncCoordinator.sync(
                    localConnections: appState.connections,
                    localGroups: appState.groups,
                    localTags: appState.tags
                )
            }
            .confirmationDialog(
                String(localized: "Delete Connection"),
                isPresented: showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let connection = connectionToDelete {
                        if selectedConnectionUUID == connection.id {
                            selectedConnectionIdString = nil
                        }
                        appState.removeConnection(connection)
                    }
                }
            } message: {
                Text("Are you sure you want to delete this connection? Saved credentials will be permanently removed.")
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Section {
                Toggle("Group by Folder", isOn: $groupByGroup)
            }

            if !appState.tags.isEmpty {
                Section("Filter by Tag") {
                    Button {
                        filterTagIdString = nil
                    } label: {
                        HStack {
                            Text("All")
                            if filterTagId == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    ForEach(appState.tags) { tag in
                        Button {
                            filterTagIdString = tag.id.uuidString
                        } label: {
                            HStack {
                                Image(systemName: "circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(ConnectionColorPicker.swiftUIColor(for: tag.color))
                                Text(tag.name)
                                if filterTagId == tag.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    showingGroupManagement = true
                } label: {
                    Label("Manage Groups", systemImage: "folder")
                }
                Button {
                    showingTagManagement = true
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    @ViewBuilder
    private var groupedContent: some View {
        let sortedGroups = appState.groups.sorted { $0.sortOrder < $1.sortOrder }

        ForEach(sortedGroups) { group in
            let groupConnections = displayedConnections.filter { $0.groupId == group.id }

            if !groupConnections.isEmpty {
                Section {
                    ForEach(groupConnections) { connection in
                        connectionRow(connection)
                    }
                    .onMove { source, destination in
                        var items = groupConnections
                        items.move(fromOffsets: source, toOffset: destination)
                        var all = appState.connections
                        for (i, item) in items.enumerated() {
                            if let idx = all.firstIndex(where: { $0.id == item.id }) {
                                all[idx].sortOrder = i
                            }
                        }
                        all.sort {
                            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        }
                        for index in all.indices { all[index].sortOrder = index }
                        appState.reorderConnections(all)
                    }
                } header: {
                    HStack(spacing: 6) {
                        if group.color != .none {
                            Circle()
                                .fill(ConnectionColorPicker.swiftUIColor(for: group.color))
                                .frame(width: 8, height: 8)
                        }
                        Text(group.name)
                    }
                }
            }
        }

        let ungrouped = displayedConnections.filter { conn in
            conn.groupId == nil || !appState.groups.contains { $0.id == conn.groupId }
        }

        if !ungrouped.isEmpty {
            Section("Ungrouped") {
                ForEach(ungrouped) { connection in
                    connectionRow(connection)
                }
                .onMove { source, destination in
                    var items = ungrouped
                    items.move(fromOffsets: source, toOffset: destination)
                    var all = appState.connections
                    for (i, item) in items.enumerated() {
                        if let idx = all.firstIndex(where: { $0.id == item.id }) {
                            all[idx].sortOrder = i
                        }
                    }
                    all.sort {
                        if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    for index in all.indices { all[index].sortOrder = index }
                    appState.reorderConnections(all)
                }
            }
        }
    }

    private func navigateToPendingConnection(_ id: UUID?) {
        guard let id,
              appState.connections.contains(where: { $0.id == id }) else { return }
        selectedConnectionIdString = id.uuidString
        appState.pendingConnectionId = nil
    }

    private func connectionRow(_ connection: DatabaseConnection) -> some View {
        NavigationLink(value: connection.id) {
            ConnectionRow(connection: connection, tag: appState.tag(for: connection.tagId))
        }
        .hoverEffect()
        .swipeActions(edge: .leading) {
            Button {
                editingConnection = connection
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                connectionToDelete = connection
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button {
                editingConnection = connection
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button {
                var duplicate = connection
                duplicate.id = UUID()
                duplicate.name = "\(connection.name) Copy"
                appState.addConnection(duplicate)
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                connectionToDelete = connection
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct ConnectionRow: View {
    let connection: DatabaseConnection
    let tag: ConnectionTag?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: connection.type))
                .font(.title3)
                .foregroundStyle(iconColor(for: connection.type))
                .frame(width: 32, height: 32)
                .background(iconColor(for: connection.type).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? connection.host : connection.name)
                    .font(.body)

                if connection.type != .sqlite {
                    Text(verbatim: "\(connection.host):\(connection.port)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(connection.database.components(separatedBy: "/").last ?? "database")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let tag {
                Text(tag.name)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(ConnectionColorPicker.swiftUIColor(for: tag.color))
                    )
            }
        }
    }

    private func iconName(for type: DatabaseType) -> String {
        switch type {
        case .mysql, .mariadb: return "cylinder"
        case .postgresql, .redshift: return "cylinder.split.1x2"
        case .sqlite: return "doc"
        case .redis: return "key"
        case .mongodb: return "leaf"
        case .clickhouse: return "bolt"
        case .mssql: return "server.rack"
        default: return "externaldrive"
        }
    }

    private func iconColor(for type: DatabaseType) -> Color {
        switch type {
        case .mysql, .mariadb: return .orange
        case .postgresql, .redshift: return .blue
        case .sqlite: return .green
        case .redis: return .red
        case .mongodb: return .green
        case .clickhouse: return .yellow
        case .mssql: return .indigo
        default: return .gray
        }
    }
}
