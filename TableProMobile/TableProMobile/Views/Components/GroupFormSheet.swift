import SwiftUI
import TableProModels

struct GroupFormSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var color: ConnectionColor
    private let existingGroup: ConnectionGroup?
    var onSave: (ConnectionGroup) -> Void

    init(editing group: ConnectionGroup? = nil, onSave: @escaping (ConnectionGroup) -> Void) {
        self.existingGroup = group
        self.onSave = onSave
        _name = State(initialValue: group?.name ?? "")
        _color = State(initialValue: group?.color ?? .none)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Color") {
                    ConnectionColorPicker(selection: $color)
                }
            }
            .navigationTitle(existingGroup != nil ? String(localized: "Edit Group") : String(localized: "New Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var group = existingGroup ?? ConnectionGroup()
                        group.name = name
                        group.color = color
                        onSave(group)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
