import SwiftUI
import TableProConnectionLibrary
import TableProModels

struct GroupManagementView: View {
    private struct GroupRow: Identifiable {
        let group: ConnectionGroup
        let depth: Int
        var id: UUID { group.id }
    }

    private enum GroupSheet: Identifiable {
        case add(parentId: UUID?)
        case edit(ConnectionGroup)

        var id: String {
            switch self {
            case .add(let parentId): "add-\(parentId?.uuidString ?? "root")"
            case .edit(let group): "edit-\(group.id.uuidString)"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: GroupSheet?
    @State private var groupToDelete: ConnectionGroup?

    private var showDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        )
    }

    var body: some View {
        let graph = LibraryGroupGraph(groups: appState.groups)
        let groupsById = Dictionary(appState.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = graph.flattened().compactMap { entry in
            groupsById[entry.id].map { GroupRow(group: $0, depth: entry.depth) }
        }
        let counts = Dictionary(grouping: appState.connections.compactMap(\.groupId), by: { $0 }).mapValues(\.count)

        NavigationStack {
            List {
                ForEach(rows) { row in
                    groupRow(row, count: counts[row.id] ?? 0, canNest: graph.canCreateSubgroup(under: row.id))
                }
                .onMove { source, destination in
                    reorder(rows: rows, graph: graph, source: source, destination: destination)
                }
            }
            .overlay {
                if appState.groups.isEmpty {
                    ContentUnavailableView {
                        Label("No Groups", systemImage: "folder")
                    } description: {
                        Text("Create a group to organize your connections.")
                    } actions: {
                        Button("Create Group") { activeSheet = .add(parentId: nil) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .confirmationDialog(
                String(localized: "Delete Group"),
                isPresented: showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    if let group = groupToDelete {
                        appState.deleteGroup(group.id)
                    }
                }
            } message: {
                if let group = groupToDelete, !graph.descendantIds(of: group.id).isEmpty {
                    Text("Its subgroups are deleted too. Their connections move to Ungrouped.")
                } else {
                    Text("Connections in this group will be moved to ungrouped.")
                }
            }
            .navigationTitle("Groups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .add(parentId: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add Group"))
                    CloseButton { dismiss() }
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .add(let parentId):
                    GroupFormSheet(parentId: parentId) { group in
                        appState.addGroup(group)
                    }
                case .edit(let group):
                    GroupFormSheet(editing: group) { updated in
                        appState.updateGroup(updated)
                    }
                }
            }
        }
    }

    private func groupRow(_ row: GroupRow, count: Int, canNest: Bool) -> some View {
        Button {
            activeSheet = .edit(row.group)
        } label: {
            ConnectionGroupRowLabel(group: row.group, connectionCount: count)
                .padding(.leading, CGFloat(row.depth) * 20)
                .foregroundStyle(.primary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                groupToDelete = row.group
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .contextMenu {
            Button {
                activeSheet = .edit(row.group)
            } label: {
                Label("Edit Group", systemImage: "pencil")
            }
            if canNest {
                Button {
                    activeSheet = .add(parentId: row.id)
                } label: {
                    Label("New Subgroup", systemImage: "folder.badge.plus")
                }
            }
            Divider()
            Button(role: .destructive) {
                groupToDelete = row.group
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Delete group")) {
            groupToDelete = row.group
        }
    }

    private func reorder(rows: [GroupRow], graph: LibraryGroupGraph, source: IndexSet, destination: Int) {
        guard let movedIndex = source.first, rows.indices.contains(movedIndex) else { return }
        let parentId = graph.parentId(of: rows[movedIndex].id)
        var ordered = rows.map(\.id)
        ordered.move(fromOffsets: source, toOffset: destination)
        appState.reorderGroups(ordered.filter { graph.parentId(of: $0) == parentId })
    }
}
