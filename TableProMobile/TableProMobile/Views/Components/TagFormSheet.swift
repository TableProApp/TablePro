import SwiftUI
import TableProModels

struct TagFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name: String
    @State private var color: ConnectionColor
    @State private var failure: LibraryWriteFailure?
    private let existingTag: ConnectionTag?
    private let opening: TagFormEdits

    init(editing tag: ConnectionTag? = nil) {
        let opening = TagFormEdits(opening: tag)
        self.existingTag = tag
        self.opening = opening
        _name = State(initialValue: opening.name)
        _color = State(initialValue: opening.color)
    }

    private var edits: TagFormEdits {
        TagFormEdits(name: name, color: color)
    }

    private var hasChanges: Bool { edits != opening }

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
            .interactiveDismissDisabled(hasChanges)
            .navigationTitle(existingTag != nil ? String(localized: "Edit Tag") : String(localized: "New Tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DiscardChangesCancelButton(hasChanges: hasChanges) { dismiss() }
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
        let outcome = edits.save(editing: existingTag, in: appState)
        failure = LibraryWriteFailure(outcome, kind: .tag)
        guard failure == nil else { return }
        dismiss()
    }
}
