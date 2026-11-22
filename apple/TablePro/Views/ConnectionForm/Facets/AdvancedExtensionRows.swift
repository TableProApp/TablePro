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
            AdvancedListEntry(
                primaryTitle: String(localized: "File"),
                secondaryTitle: String(localized: "Entry Point"),
                notice: LoadableExtensionFileIssue.issue(forPath: entry.path)?.message,
                actionsLabel: String(
                    format: String(localized: "Actions for %@"),
                    (entry.path as NSString).lastPathComponent
                ),
                canMoveUp: index > 0,
                canMoveDown: index < model.rows.count - 1,
                onMove: { offset in move(entry.id, by: offset) },
                onRemove: { remove(entry.id) }
            ) {
                TextField(
                    String(localized: "Extension File"),
                    text: pathBinding(for: entry.id),
                    prompt: Text(verbatim: "/opt/homebrew/lib/mod_spatialite.dylib")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused($focusedEntry, equals: entry.id)
            } secondary: {
                TextField(
                    String(localized: "Entry Point"),
                    text: entryPointBinding(for: entry.id),
                    prompt: Text(String(localized: "Default entry point"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .help(String(localized: "The initialization function to call. Leave empty to use the one SQLite derives from the file name."))
            }
        }

        if model.isUnreadable {
            NoticeLabel(String(localized: "The saved list could not be read. Adding an extension replaces it."))
        }

        LabeledContent {
            Button(String(localized: "Add Extension…")) {
                Task { await chooseFiles() }
            }
            .accessibilityIdentifier("connection-extensions-add")
        } label: {
            if let issue = store.revealedIssue(for: row) {
                NoticeLabel(issue.message, severity: issue.noticeSeverity)
            } else if model.rows.isEmpty {
                Text(String(localized: "No Extensions"))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: value.wrappedValue) { _ in reload() }
        .onEditorFocusRequest(row, store: store) { focusedEntry = model.rows.first?.id }
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

    private func chooseFiles() async {
        let panel = NSOpenPanel()
        let validator = AdvancedExtensionPanelValidator()
        panel.title = String(localized: "Add Extension")
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose the SQLite extension libraries to load when this connection opens.")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = AdvancedExtensionPanelValidator.contentTypes
        panel.delegate = validator
        let response: NSApplication.ModalResponse
        if let window = EditorFilePanel.window(for: store) {
            response = await panel.presentAsSheet(for: window)
        } else {
            response = await panel.begin()
        }
        withExtendedLifetime(validator) {}
        guard response == .OK else { return }
        _ = model.add(paths: panel.urls.map { $0.path(percentEncoded: false) })
        commit()
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
                    format: String(localized: "\"%@\" is not a library."),
                    url.lastPathComponent
                )
            ]
        )
    }
}
