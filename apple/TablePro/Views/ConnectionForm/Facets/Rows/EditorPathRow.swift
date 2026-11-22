//
//  EditorPathRow.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorPathRow: View {
    private let title: String
    @Binding private var path: String
    private let prompt: String?
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let buttonTitle: String
    private let choose: @MainActor () async -> String?

    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        path: Binding<String>,
        prompt: String? = nil,
        row: EditorRow,
        store: ConnectionEditorStore,
        buttonTitle: String = String(localized: "Choose…"),
        choose: @escaping @MainActor () async -> String?
    ) {
        self.title = title
        _path = path
        self.prompt = prompt
        self.row = row
        self.store = store
        self.buttonTitle = buttonTitle
        self.choose = choose
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(text: store.tracking($path, row: row), prompt: Text(verbatim: EditorFieldPrompt.text(prompt, row: row, store: store))) {
                    Text(verbatim: title)
                }
                .labelsHidden()
                .autocorrectionDisabled()
                .editorPathField(path)
                .focused($isFocused)
                .accessibilityIdentifier(row.accessibilityIdentifier)

                Button(buttonTitle) {
                    Task {
                        if let chosen = await choose() { pick(chosen) }
                    }
                }
                .accessibilityIdentifier("\(row.accessibilityIdentifier)-choose")
            }
        } label: {
            EditorRowLabel(title, row: row, store: store)
        }
        .editorRowFocus(row, store: store, isFocused: $isFocused)
    }

    private func pick(_ chosen: String) {
        store.noteEdited(row)
        path = chosen
    }
}

// A database file path with Choose… for a file that exists and New… for one the driver creates at connect.
struct EditorDatabaseFileRow: View {
    private let title: String
    @Binding private var path: String
    private let prompt: String?
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let chooseIdentifier: String
    private let newIdentifier: String

    @FocusState private var isFocused: Bool

    init(
        _ title: String,
        path: Binding<String>,
        prompt: String?,
        row: EditorRow,
        store: ConnectionEditorStore,
        chooseIdentifier: String,
        newIdentifier: String
    ) {
        self.title = title
        _path = path
        self.prompt = prompt
        self.row = row
        self.store = store
        self.chooseIdentifier = chooseIdentifier
        self.newIdentifier = newIdentifier
    }

    private var newFileExtensions: [String] { store.traits.newDatabaseFileExtensions }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(text: store.tracking($path, row: row), prompt: Text(verbatim: EditorFieldPrompt.text(prompt, row: row, store: store))) {
                    Text(verbatim: title)
                }
                .labelsHidden()
                .autocorrectionDisabled()
                .editorPathField(path)
                .focused($isFocused)
                .accessibilityIdentifier(row.accessibilityIdentifier)

                Button(String(localized: "Choose…")) {
                    Task { await chooseExisting() }
                }
                .help(String(localized: "Choose an existing database file"))
                .accessibilityIdentifier(chooseIdentifier)

                if !newFileExtensions.isEmpty {
                    Button(String(localized: "New…")) {
                        Task { await nameNew() }
                    }
                    .help(String(localized: "Name a new database file, created when you connect"))
                    .accessibilityIdentifier(newIdentifier)
                }
            }
        } label: {
            EditorRowLabel(title, row: row, store: store)
        }
        .editorRowFocus(row, store: store, isFocused: $isFocused)
    }

    private func pick(_ chosen: String) {
        store.noteEdited(row)
        path = chosen
    }

    private func chooseExisting() async {
        let chosen = await DatabaseFilePanel.chooseExisting(
            for: store.draft.type,
            currentPath: path,
            in: EditorFilePanel.window(for: store)
        )
        if let chosen { pick(chosen) }
    }

    private func nameNew() async {
        let chosen = await DatabaseFilePanel.nameNew(
            extensions: newFileExtensions,
            currentPath: path,
            in: EditorFilePanel.window(for: store)
        )
        if let chosen { pick(chosen) }
    }
}

extension View {
    // A long path keeps its file name in sight: the middle gives way, the tooltip has it whole, and the ideal width
    // keeps the row on one line where the path's own width would stack the label above it.
    func editorPathField(_ path: String) -> some View {
        truncationMode(.middle)
            .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
            .help(path)
    }
}

// Open and save panels for the editor's path rows.
@MainActor
enum EditorFilePanel {
    static func window(for store: ConnectionEditorStore) -> NSWindow? {
        store.window ?? NSApp.keyWindow
    }

    // A sheet on the window it serves, also when the panel is wider than the editor, as open and save panels are on macOS.
    static func present(_ panel: NSSavePanel, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return await panel.begin() }
        return await panel.presentAsSheet(for: window)
    }

    static func chooseFile(
        in window: NSWindow?,
        message: String? = nil,
        contentTypes: [UTType] = [.data],
        showsHiddenFiles: Bool = false,
        currentPath: String = ""
    ) async -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes
        panel.showsHiddenFiles = showsHiddenFiles
        if let message { panel.message = message }
        let trimmed = currentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        }
        guard await present(panel, in: window) == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}
