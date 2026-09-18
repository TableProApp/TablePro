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
    private let opening: GroupFormEdits

    init(editing group: ConnectionGroup? = nil, parentId: UUID? = nil) {
        let opening = GroupFormEdits(opening: group, parentId: parentId)
        self.existingGroup = group
        self.opening = opening
        _name = State(initialValue: opening.name)
        _color = State(initialValue: opening.color)
        _parentId = State(initialValue: opening.parentId)
    }

    private var edits: GroupFormEdits {
        GroupFormEdits(name: name, color: color, parentId: parentId)
    }

    private var hasChanges: Bool { edits != opening }

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
            .interactiveDismissDisabled(hasChanges)
            .navigationTitle(existingGroup != nil ? String(localized: "Edit Group") : String(localized: "New Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DiscardChangesCancelButton(hasChanges: hasChanges) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Save", action: save)
                        .disabled(edits.name.isEmpty)
                }
            }
            .libraryWriteFailureAlert(failure, onDismiss: { failure = nil }, closeForm: { dismiss() })
        }
    }

    private func save() {
        let outcome = edits.save(editing: existingGroup, in: appState)
        failure = LibraryWriteFailure(outcome, kind: .group)
        guard failure == nil else { return }
        dismiss()
    }
}
