import SwiftUI
import TableProConnectionLibrary
import TableProModels

struct GroupFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name: String
    @State private var color: ConnectionColor
    @State private var parentId: UUID?
    @State private var failure: LibraryWriteFailure?
    private let existingGroup: ConnectionGroup?

    init(editing group: ConnectionGroup? = nil, parentId: UUID? = nil) {
        self.existingGroup = group
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
                    ConfirmButton(title: "Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .libraryWriteFailureAlert(failure, onDismiss: { failure = nil }, closeForm: { dismiss() })
        }
    }

    private func save() {
        let outcome = GroupFormEdits(name: name, color: color, parentId: parentId)
            .save(editing: existingGroup, in: appState)
        failure = LibraryWriteFailure(outcome, kind: .group)
        guard failure == nil else { return }
        dismiss()
    }
}
