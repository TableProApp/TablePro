import AppKit
import SwiftUI

// The attached databases as rows of their section; the entries keep ids across edits, the stored value does not.
struct AdvancedAttachedDatabaseRows: View {
    let fieldID: String
    @ObservedObject var store: ConnectionEditorStore

    @State private var model = AttachedDatabaseListModel(encoded: "")
    @State private var isEdited = false
    @FocusState private var focusedEntry: UUID?
    @State private var handledFocusToken: UUID?

    private var row: EditorRow { .plugin(fieldID: fieldID) }
    private var value: Binding<String> { store.pluginFieldBinding(fieldID) }

    var body: some View {
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, entry in
            AdvancedListEntry(
                primaryTitle: String(localized: "Name"),
                secondaryTitle: String(localized: "File"),
                notice: AttachedDatabaseFileIssue.issue(forPath: entry.path)?.message,
                actionsLabel: String(format: String(localized: "Actions for %@"), entry.name),
                canMoveUp: index > 0,
                canMoveDown: index < model.rows.count - 1,
                onMove: { offset in move(entry.id, by: offset) },
                onRemove: { remove(entry.id) }
            ) {
                TextField(String(localized: "Name"), text: nameBinding(for: entry.id))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedEntry, equals: entry.id)
                    .help(String(localized: "The name a statement uses for this database, as in name.table."))
            } secondary: {
                TextField(
                    String(localized: "Database File"),
                    text: pathBinding(for: entry.id),
                    prompt: Text(verbatim: "/path/to/database.db")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            }
        }

        if model.isUnreadable {
            NoticeLabel(String(localized: "The saved list could not be read. Adding a database replaces it."))
        }

        LabeledContent {
            Button(String(localized: "Attach Database…")) {
                Task { await chooseFiles() }
            }
            .accessibilityIdentifier("connection-attached-databases-add")
        } label: {
            if let issue = EditorIssueVisibility.issue(for: row, in: store, isEdited: isEdited) {
                NoticeLabel(issue.message, severity: issue.severity == .error ? .error : .warning)
            } else if model.rows.isEmpty {
                Text(String(localized: "No Attached Databases"))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            reload()
            focus(store.focusRequest)
        }
        .onChange(of: value.wrappedValue) { _ in reload() }
        .onChange(of: store.focusRequest) { focus($0) }
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

    private func pathBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.rows.first { $0.id == id }?.path ?? "" },
            set: { newValue in
                model.setPath(newValue, for: id)
                commit()
            }
        )
    }

    private func reload() {
        guard !model.matches(encoded: value.wrappedValue) else { return }
        model = AttachedDatabaseListModel(encoded: value.wrappedValue)
    }

    private func commit() {
        isEdited = true
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

    // The issue names no entry, so the first name field takes the focus.
    private func focus(_ request: FocusRequest?) {
        guard let request, request.row == row, request.token != handledFocusToken else { return }
        handledFocusToken = request.token
        let target = model.rows.first?.id
        DispatchQueue.main.async { focusedEntry = target }
    }

    private func chooseFiles() async {
        let panel = NSOpenPanel()
        let rule = DatabaseFileBrowseRule(type: store.draft.type, extensions: store.traits.fileExtensions)
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled)
        panel.title = String(localized: "Attach Database")
        panel.prompt = String(localized: "Attach")
        panel.message = String(localized: "Choose the database files to attach each time this connection opens.")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.delegate = filter
        let response: NSApplication.ModalResponse
        if let window = EditorFilePanel.window(for: store) {
            response = await panel.presentAsSheet(for: window)
        } else {
            response = await panel.begin()
        }
        withExtendedLifetime(filter) {}
        guard response == .OK else { return }
        _ = model.add(paths: panel.urls.map { $0.path(percentEncoded: false) })
        commit()
    }
}
