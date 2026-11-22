import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The extension libraries as rows of their section, loaded in this order; Add is the only way an entry is created.
struct AdvancedExtensionRows: View {
    let fieldID: String
    @ObservedObject var store: ConnectionEditorStore

    @State private var model = LoadableExtensionListModel(encoded: "")
    @FocusState private var focusedEntry: UUID?

    private var row: EditorRow { .plugin(fieldID: fieldID) }
    private var value: Binding<String> { store.pluginFieldBinding(fieldID) }

    var body: some View {
        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, entry in
            let fileName = (entry.path as NSString).lastPathComponent
            AdvancedListEntry(
                path: entry.path,
                notice: LoadableExtensionFileIssue.issue(forPath: entry.path)?.message,
                actionsLabel: String(format: String(localized: "Actions for %@"), fileName),
                identifier: "connection-extension-\(index)",
                canMoveUp: index > 0,
                canMoveDown: index < model.rows.count - 1,
                onMove: { offset in move(entry.id, by: offset) },
                onChangeFile: { Task { await changeFile(of: entry.id) } },
                onRemove: { remove(entry.id) }
            ) {
                Text(verbatim: fileName)
            } value: {
                TextField(
                    String(localized: "Entry Point"),
                    text: entryPointBinding(for: entry.id),
                    prompt: Text(String(localized: "Default entry point"))
                )
                .labelsHidden()
                .autocorrectionDisabled()
                .frame(minWidth: 0, idealWidth: 140, maxWidth: .infinity)
                .focused($focusedEntry, equals: entry.id)
                .help(String(localized: "The initialization function to call. Leave empty to use the one SQLite derives from the file name."))
                .accessibilityIdentifier("connection-extension-\(index)-entry-point")
            }
        }

        if model.isUnreadable {
            NoticeLabel(String(localized: "The saved list could not be read. Adding an extension replaces it."))
        }

        LabeledContent {
            Button(String(localized: "Add Extension…")) {
                Task { await add() }
            }
            .accessibilityIdentifier("connection-extensions-add")
        } label: {
            if let issue = store.revealedIssue(for: row) {
                NoticeLabel(issue.message, severity: issue.noticeSeverity)
            } else if model.rows.isEmpty {
                Text(String(localized: "No Extensions"))
                    .foregroundStyle(.secondary)
            } else {
                Text("^[\(model.rows.count) Extension](inflect: true)")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: value.wrappedValue) { _ in reload() }
        .onEditorFocusRequest(row, store: store) { focusedEntry = model.rows.first?.id }
    }

    private func entryPointBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { model.rows.first { $0.id == id }?.entryPoint ?? "" },
            set: { newValue in
                model.setEntryPoint(newValue, for: id)
                commit()
            }
        )
    }

    private func reload() {
        guard !model.matches(encoded: value.wrappedValue) else { return }
        model = LoadableExtensionListModel(encoded: value.wrappedValue)
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

    private func add() async {
        let paths = await chooseFiles(
            title: String(localized: "Add Extension"),
            prompt: String(localized: "Add"),
            message: String(localized: "Choose the SQLite extension libraries to load when this connection opens."),
            allowsMultipleSelection: true
        )
        guard !paths.isEmpty else { return }
        _ = model.add(paths: paths)
        commit()
    }

    // The entry keeps its entry point and its place; only the library it loads changes.
    private func changeFile(of id: UUID) async {
        guard let entry = model.rows.first(where: { $0.id == id }) else { return }
        let paths = await chooseFiles(
            title: String(localized: "Change File"),
            prompt: String(localized: "Choose"),
            message: String(localized: "Choose the SQLite extension library to load in its place."),
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
        let validator = AdvancedExtensionPanelValidator()
        panel.title = title
        panel.prompt = prompt
        panel.message = message
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = AdvancedExtensionPanelValidator.contentTypes
        panel.directoryURL = DatabaseFileLocation(path: currentPath).existingFolder
        panel.delegate = validator
        let response = await EditorFilePanel.present(panel, in: EditorFilePanel.window(for: store))
        withExtendedLifetime(validator) {}
        guard response == .OK else { return [] }
        return panel.urls.map { $0.path(percentEncoded: false) }
    }
}

// The panel's content types only dim other files and `.so` has no type of its own, so a pick is checked here too.
private final class AdvancedExtensionPanelValidator: NSObject, NSOpenSavePanelDelegate {
    static let contentTypes: [UTType] = [
        UTType(filenameExtension: "dylib"),
        UTType(filenameExtension: "so"),
        UTType(filenameExtension: "bundle")
    ]
    .compactMap { $0 }

    func panel(_ sender: Any, validate url: URL) throws {
        guard !MachOFile.isMachO(atPath: url.path(percentEncoded: false)) else { return }
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadCorruptFileError,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: String(localized: "“%@” isn’t a library."),
                    url.lastPathComponent
                )
            ]
        )
    }
}
