import SwiftUI
import TableProConnectionLibrary
import TableProModels

struct GroupFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name: String
    @State private var color: ConnectionColor
    @State private var parentId: UUID?
    private let existingGroup: ConnectionGroup?
    var onSave: (ConnectionGroup) -> Void

    init(
        editing group: ConnectionGroup? = nil,
        parentId: UUID? = nil,
        onSave: @escaping (ConnectionGroup) -> Void
    ) {
        self.existingGroup = group
        self.onSave = onSave
        _name = State(initialValue: group?.name ?? "")
        _color = State(initialValue: group?.color ?? .none)
        _parentId = State(initialValue: group?.parentId ?? parentId)
    }

    private var placementGroupId: UUID {
        existingGroup?.id ?? UUID()
    }

    var body: some View {
        let graph = LibraryGroupGraph(groups: appState.groups)
        let groupId = placementGroupId
        let parents = graph.flattened().filter { graph.canPlace(groupId, under: $0.id) }
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                if !parents.isEmpty || parentId != nil {
                    Section {
                        Picker("Parent Group", selection: $parentId) {
                            Text("None").tag(UUID?.none)
                            ForEach(parents, id: \.id) { entry in
                                Text(graph.pathNames(to: entry.id).joined(separator: " / "))
                                    .tag(Optional(entry.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Color") {
                    ConnectionColorPicker(selection: $color)
                }
            }
            .navigationTitle(existingGroup != nil ? String(localized: "Edit Group") : String(localized: "New Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Save") {
                        var group = existingGroup ?? ConnectionGroup()
                        group.name = name.trimmingCharacters(in: .whitespaces)
                        group.color = color
                        group.parentId = parentId
                        onSave(group)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
