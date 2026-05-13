import SwiftUI
import TableProModels

struct TagFormSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var color: ConnectionColor
    private let existingTag: ConnectionTag?
    var onSave: (ConnectionTag) -> Void

    init(editing tag: ConnectionTag? = nil, onSave: @escaping (ConnectionTag) -> Void) {
        self.existingTag = tag
        self.onSave = onSave
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: tag?.color ?? .gray)
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
            .navigationTitle(existingTag != nil ? String(localized: "Edit Tag") : String(localized: "New Tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var tag = existingTag ?? ConnectionTag()
                        tag.name = name
                        tag.color = color
                        onSave(tag)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
