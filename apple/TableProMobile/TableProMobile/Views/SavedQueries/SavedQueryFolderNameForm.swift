import SwiftUI
import TableProModels

struct SavedQueryFolderNameForm: View {
    enum Mode: Hashable {
        case create(parentId: UUID?)
        case rename(SavedQueryFolder)
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool
    @State private var name: String
    @State private var failure: SavedQueryWriteFailure?

    private let mode: Mode
    private let connectionId: UUID
    private let onCreated: (SavedQueryFolder) -> Void

    init(mode: Mode, connectionId: UUID, onCreated: @escaping (SavedQueryFolder) -> Void = { _ in }) {
        self.mode = mode
        self.connectionId = connectionId
        self.onCreated = onCreated
        _name = State(initialValue: Self.currentName(for: mode) ?? "")
    }

    private static func currentName(for mode: Mode) -> String? {
        guard case .rename(let folder) = mode else { return nil }
        return folder.name
    }

    private var isCreating: Bool {
        switch mode {
        case .create:
            true
        case .rename:
            false
        }
    }

    private var acceptedName: String? {
        SavedQueryDraft.acceptedName(name, replacing: Self.currentName(for: mode))
    }

    private var hasChanges: Bool {
        name != (Self.currentName(for: mode) ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($isNameFocused)
                    .onSubmit(save)
            }
        }
        .navigationTitle(isCreating ? String(localized: "New Folder") : String(localized: "Rename Folder"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(hasChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DiscardChangesCancelButton(hasChanges: hasChanges) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(title: "Save", action: save)
                    .disabled(acceptedName == nil)
            }
        }
        .onAppear { isNameFocused = true }
        .savedQueryWriteFailureAlert($failure)
    }

    private func save() {
        guard let accepted = acceptedName else { return }
        let store = appState.savedQueries
        switch mode {
        case .create(let parentId):
            let folder = SavedQueryFolder(name: accepted, parentId: parentId, connectionId: connectionId)
            guard store.insertFolder(folder) else {
                failure = .notSaved
                return
            }
            onCreated(folder)
        case .rename(let folder):
            let renamed = store.updateFolder(folder.id) { $0.name = accepted }
            guard renamed else {
                failure = .failedFolderWrite(folder.id, in: store.contents.folders)
                return
            }
        }
        dismiss()
    }
}
