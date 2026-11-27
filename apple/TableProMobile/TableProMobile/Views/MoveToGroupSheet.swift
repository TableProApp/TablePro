import SwiftUI
import TableProConnectionLibrary
import TableProModels

struct MoveToGroupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // As chosen when the sheet opened. A sync can take some out of the active project while it is up.
    let requestedConnectionIds: [UUID]

    init(connectionIds: [UUID]) {
        requestedConnectionIds = connectionIds
    }

    private var connectionIds: [UUID] {
        ConnectionListSelection.connectionIds(requestedConnectionIds, scopedTo: appState.scopedConnectionIds)
    }

    private var currentGroupIds: Set<UUID?> {
        let validGroupIds = Set(appState.groups.map(\.id))
        let ids = Set(connectionIds)
        return Set(appState.connections.filter { ids.contains($0.id) }.map {
            ConnectionLibraryEditing.effectiveGroupId(of: $0, validGroupIds: validGroupIds)
        })
    }

    var body: some View {
        // Only the active project's groups: a group of another project would take the connection out of the list.
        let groups = appState.scopedGroups
        let graph = LibraryGroupGraph(groups: groups)
        let groupsById = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List {
                Section {
                    destinationRow(
                        title: String(localized: "Ungrouped"),
                        systemImage: "tray",
                        color: .none,
                        depth: 0,
                        groupId: nil
                    )
                }
                if !groups.isEmpty {
                    Section("Groups") {
                        ForEach(graph.flattened(), id: \.id) { entry in
                            if let group = groupsById[entry.id] {
                                destinationRow(
                                    title: group.name,
                                    systemImage: LibraryGlyph.groupSymbol(group.iconName),
                                    color: group.color,
                                    depth: entry.depth,
                                    groupId: group.id
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle(connectionIds.count == 1
                ? String(localized: "Move Connection")
                : String(format: String(localized: "Move %d Connections"), connectionIds.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
            }
            .onChange(of: connectionIds.isEmpty) { _, isEmpty in
                guard isEmpty else { return }
                dismiss()
            }
        }
    }

    private func destinationRow(
        title: String,
        systemImage: String,
        color: ConnectionColor,
        depth: Int,
        groupId: UUID?
    ) -> some View {
        let isCurrent = currentGroupIds == [groupId]
        return Button {
            appState.moveConnections(connectionIds, toGroup: groupId)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(color == .none ? Color.secondary : ConnectionColorPicker.swiftUIColor(for: color))
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
