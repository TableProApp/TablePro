import SwiftUI
import TableProModels

struct TagFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name: String
    @State private var color: ConnectionColor
    @State private var failure: LibraryWriteFailure?
    private let existingTag: ConnectionTag?

    init(editing tag: ConnectionTag? = nil) {
        self.existingTag = tag
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
        let outcome = TagFormEdits(name: name, color: color).save(editing: existingTag, in: appState)
        failure = LibraryWriteFailure(outcome, kind: .tag)
        guard failure == nil else { return }
        dismiss()
    }
}
