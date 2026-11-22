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

    @State private var isEdited = false
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
                TextField(text: $path, prompt: prompt.map { Text(verbatim: $0) }) {
                    Text(verbatim: title)
                }
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($isFocused)
                .accessibilityIdentifier(row.accessibilityIdentifier)

                Button(buttonTitle) {
                    Task {
                        if let chosen = await choose() { path = chosen }
                    }
                }
                .accessibilityIdentifier("\(row.accessibilityIdentifier)-choose")
            }
        } label: {
            EditorRowLabel(title, row: row, store: store, isEdited: isEdited)
        }
        .editorRowFocus(row, store: store, isFocused: $isFocused)
        .onChange(of: path) { _ in isEdited = true }
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

    @State private var isEdited = false
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
                TextField(text: $path, prompt: prompt.map { Text(verbatim: $0) }) {
                    Text(verbatim: title)
                }
                .labelsHidden()
                .autocorrectionDisabled()
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
            EditorRowLabel(title, row: row, store: store, isEdited: isEdited)
        }
        .editorRowFocus(row, store: store, isFocused: $isFocused)
        .onChange(of: path) { _ in isEdited = true }
    }

    private func chooseExisting() async {
        let chosen = await DatabaseFilePanel.chooseExisting(
            for: store.draft.type,
            currentPath: path,
            in: EditorFilePanel.window(for: store)
        )
        if let chosen { path = chosen }
    }

    private func nameNew() async {
        let chosen = await DatabaseFilePanel.nameNew(
            extensions: newFileExtensions,
            currentPath: path,
            in: EditorFilePanel.window(for: store)
        )
        if let chosen { path = chosen }
    }
}

// Open panels for the editor's path rows, as sheets on the editor window.
@MainActor
enum EditorFilePanel {
    static func window(for store: ConnectionEditorStore) -> NSWindow? {
        store.window ?? NSApp.keyWindow
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
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.presentAsSheet(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}
