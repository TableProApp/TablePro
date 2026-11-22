import AppKit
import SwiftUI

// The attached databases as rows of their section; the entries keep ids across edits, the stored value does not.
struct AdvancedAttachedDatabaseRows: View {
    let fieldID: String
    @ObservedObject var store: ConnectionEditorStore

    @State private var model = AttachedDatabaseListModel(encoded: "")
    @FocusState private var focusedEntry: UUID?

    private var row: EditorRow { .plugin(fieldID: fieldID) }
    private var value: Binding<String> { store.pluginFieldBinding(fieldID) }

    var body: some View {
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, entry in
            AdvancedListEntry(
                path: entry.path,
                notice: AttachedDatabaseFileIssue.issue(forPath: entry.path)?.message,
                actionsLabel: String(format: String(localized: "Actions for %@"), entry.name),
                identifier: "connection-attached-database-\(index)",
                canMoveUp: index > 0,
                canMoveDown: index < model.rows.count - 1,
                onMove: { offset in move(entry.id, by: offset) },
                onChangeFile: { Task { await changeFile(of: entry.id) } },
                onRemove: { remove(entry.id) }
            ) {
                // The name a statement reaches it by, edited where it reads.
                TextField(text: nameBinding(for: entry.id), prompt: Text(String(localized: "Name"))) {
                    Text(String(localized: "Name"))
                }
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($focusedEntry, equals: entry.id)
                .help(String(localized: "The name a statement uses for this database, as in name.table."))
                .accessibilityIdentifier("connection-attached-database-\(index)-name")
            } value: {
                EmptyView()
            }
        }

        if model.isUnreadable {
            NoticeLabel(String(localized: "The saved list could not be read. Adding a database replaces it."))
        }

        LabeledContent {
            Button(String(localized: "Attach Database…")) {
                Task { await attach() }
            }
            .accessibilityIdentifier("connection-attached-databases-add")
        } label: {
            if let issue = store.revealedIssue(for: row) {
                NoticeLabel(issue.message, severity: issue.noticeSeverity)
            } else if model.rows.isEmpty {
                Text(String(localized: "No Attached Databases"))
                    .foregroundStyle(.secondary)
            } else {
                Text("^[\(model.rows.count) Attached Database](inflect: true)")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: value.wrappedValue) { _ in reload() }
        .onEditorFocusRequest(row, store: store) { focusedEntry = model.rows.first?.id }
    }

    private func nameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.rows.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                model.setName(newValue, for: id)
                commit()
            }
        )
    }

    private func reload() {
        guard !model.matches(encoded: value.wrappedValue) else { return }
        model = AttachedDatabaseListModel(encoded: value.wrappedValue)
    }

    private func commit() {
        store.noteEdited(row)
        let encoded = model.encoded
        guard value.wrappedValue != encoded else { return }
        value.wrappedValue = encoded
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard model.rows.indices.contains(target) else { return }
        model.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
        commit()
    }

    private func remove(_ id: UUID) {
        _ = model.remove([id])
        commit()
    }

    private func attach() async {
        let paths = await chooseFiles(
            title: String(localized: "Attach Database"),
            prompt: String(localized: "Attach"),
            message: String(localized: "Choose the database files to attach each time this connection opens."),
            allowsMultipleSelection: true
        )
        guard !paths.isEmpty else { return }
        _ = model.add(paths: paths)
        commit()
    }

    // The entry keeps its name and its place; only the file it names changes.
    private func changeFile(of id: UUID) async {
        guard let entry = model.rows.first(where: { $0.id == id }) else { return }
        let paths = await chooseFiles(
            title: String(localized: "Change File"),
            prompt: String(localized: "Choose"),
            message: String(format: String(localized: "Choose the database file to attach as “%@”."), entry.name),
            allowsMultipleSelection: false,
            currentPath: entry.path
        )
        guard let path = paths.first else { return }
        model.setPath(path, for: id)
        commit()
    }

    private func chooseFiles(
        title: String,
        prompt: String,
        message: String,
        allowsMultipleSelection: Bool,
        currentPath: String = ""
    ) async -> [String] {
        let panel = NSOpenPanel()
        let rule = DatabaseFileBrowseRule.forType(store.draft.type, extensions: store.traits.fileExtensions)
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled, validate: rule.validate)
        panel.title = title
        panel.prompt = prompt
        panel.message = message
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.directoryURL = DatabaseFileLocation(path: currentPath).existingFolder
        panel.delegate = filter
        let response = await EditorFilePanel.present(panel, in: EditorFilePanel.window(for: store))
        withExtendedLifetime(filter) {}
        guard response == .OK else { return [] }
        return panel.urls.map { $0.path(percentEncoded: false) }
    }
}
