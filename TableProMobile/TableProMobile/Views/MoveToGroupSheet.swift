import SwiftUI
import TableProConnectionLibrary
import TableProModels

struct MoveToGroupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let connectionIds: [UUID]

    private var currentGroupIds: Set<UUID?> {
        let validGroupIds = Set(appState.groups.map(\.id))
        let ids = Set(connectionIds)
        return Set(appState.connections.filter { ids.contains($0.id) }.map {
            ConnectionLibraryEditing.effectiveGroupId(of: $0, validGroupIds: validGroupIds)
        })
    }

    var body: some View {
        let graph = LibraryGroupGraph(groups: appState.groups)
        let groupsById = Dictionary(appState.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List {
                Section {
                    destinationRow(title: String(localized: "Ungrouped"), color: nil, depth: 0, groupId: nil)
                }
                if !appState.groups.isEmpty {
                    Section("Groups") {
                        ForEach(graph.flattened(), id: \.id) { entry in
                            if let group = groupsById[entry.id] {
                                destinationRow(title: group.name, color: group.color, depth: entry.depth, groupId: group.id)
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
        }
    }

    private func destinationRow(title: String, color: ConnectionColor?, depth: Int, groupId: UUID?) -> some View {
        let isCurrent = currentGroupIds == [groupId]
        return Button {
            appState.moveConnections(connectionIds, toGroup: groupId)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: groupId == nil ? "tray" : "folder.fill")
                    .foregroundStyle(color.map(ConnectionColorPicker.swiftUIColor(for:)) ?? .secondary)
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
