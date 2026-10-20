import SwiftUI
import TableProModels

struct SavedQueryFormView: View {
    private enum Mode {
        case new(sql: String)
        case edit(SavedQuery)
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SavedQueryDraft
    @State private var failure: SavedQueryWriteFailure?

    private let mode: Mode
    private let connectionId: UUID
    private let opening: SavedQueryDraft

    // Seeded here, not in onAppear, so the opening scope never reaches onChange and drops the folder.
    init(newQuery sql: String, connectionId: UUID) {
        let opening = SavedQueryDraft(saving: sql)
        mode = .new(sql: sql)
        self.connectionId = connectionId
        self.opening = opening
        _draft = State(initialValue: opening)
    }

    init(editing query: SavedQuery, connectionId: UUID) {
        let opening = SavedQueryDraft(query: query)
        mode = .edit(query)
        self.connectionId = connectionId
        self.opening = opening
        _draft = State(initialValue: opening)
    }

    private var sql: String {
        switch mode {
        case .new(let text):
            text
        case .edit(let query):
            query.query
        }
    }

    private var editingId: UUID? {
        guard case .edit(let query) = mode else { return nil }
        return query.id
    }

    private var hasChanges: Bool {
        draft != opening
    }

    var body: some View {
        let store = appState.savedQueries
        let folders = store.contents(visibleTo: connectionId).folders
        let scope = draft.scope(in: connectionId)
        let validation = currentValidation(in: store)
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .submitLabel(.done)
                if !folders.isEmpty || draft.folderId != nil {
                    NavigationLink {
                        SavedQueryFolderPicker(
                            folders: folders,
                            selection: draft.folderId,
                            recordScope: scope,
                            title: String(localized: "Folder")
                        ) { draft.folderId = $0 }
                    } label: {
                        LabeledContent("Folder") {
                            Text(verbatim: folderName(in: store.contents.folders))
                        }
                    }
                }
            } footer: {
                if SavedQueryDraft.hidesFolders(folders, forScope: scope) {
                    Text("Only folders available in all connections can hold a global query.")
                }
            }

            Section {
                TextField("Keyword", text: $draft.keyword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fontDesign(.monospaced)
                Toggle(isOn: $draft.isGlobal) {
                    Text("Global")
                    Text("Available in all connections")
                }
            } footer: {
                if let message = validation.keywordCheck.message {
                    Text(verbatim: message)
                        .foregroundStyle(validation.keywordCheck.blocksSave ? Color.red : Color.orange)
                }
            }

            if validation.exceedsSizeLimit {
                Section {
                    Text(verbatim: SavedQueryDraft.sizeLimitMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(editingId == nil ? String(localized: "Save Query") : String(localized: "Edit Query"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(hasChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                DiscardChangesCancelButton(hasChanges: hasChanges) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                ConfirmButton(title: "Save") { save() }
                    .disabled(!draft.canSave(sql: sql, validation: validation))
            }
        }
        .onChange(of: draft.isGlobal) {
            draft = draft.resolvingFolder(among: appState.savedQueries.contents.folders, connectionId: connectionId)
        }
        .savedQueryWriteFailureAlert($failure)
    }

    private func folderName(in folders: [SavedQueryFolder]) -> String {
        guard let folderId = draft.folderId, let folder = folders.first(where: { $0.id == folderId }) else {
            return String(localized: "None")
        }
        return folder.name
    }

    private func currentValidation(in store: SavedQueryLibrary) -> SavedQueryValidation {
        let editingId = editingId
        return draft.validation(
            sql: sql,
            savingOver: editingId.flatMap { store.contents.query($0) },
            changedSince: opening,
            connectionId: connectionId,
            folders: store.contents.folders
        ) { store.isKeywordAvailable($0, connectionId: $1, excluding: editingId) }
    }

    private func save() {
        let store = appState.savedQueries
        guard draft.canSave(sql: sql, validation: currentValidation(in: store)) else { return }
        switch mode {
        case .new(let text):
            guard store.insert(draft.newQuery(sql: text, connectionId: connectionId)) else {
                failure = .notSaved
                return
            }
        case .edit(let query):
            let edits = draft
            let openingEdits = opening
            let ownerId = connectionId
            let folders = store.contents.folders
            let updated = store.update(query.id) { live in
                edits.apply(to: &live, changedSince: openingEdits, connectionId: ownerId, folders: folders)
            }
            // The form stays open on a deleted query, so the typed name and keyword are not lost.
            guard updated else {
                failure = .failedQueryWrite(query.id, in: store.contents.queries)
                return
            }
        }
        dismiss()
    }
}
