//
//  LoadableExtensionListEditor.swift
//  TablePro
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The ordered list of SQLite extension libraries a connection loads, edited in place.
///
/// Built like the other lists in this form: a bordered list with the add and remove pair beneath
/// it, rows reordered by dragging or with the Move Up and Move Down accessibility actions, and
/// Delete removing the selection. Add opens a file panel, the only way a row is created; once it
/// exists, its path and entry point are edited in place.
struct LoadableExtensionListEditor: View {
    @Binding var value: String

    @State private var model = LoadableExtensionListModel(encoded: "")
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            list
            if model.isUnreadable {
                Label(
                    String(localized: "The saved list could not be read. Adding an extension replaces it."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { reload() }
        .onChange(of: value) { _ in reload() }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.rows) { row in
                LoadableExtensionRowView(
                    path: pathBinding(for: row.id),
                    entryPoint: entryPointBinding(for: row.id),
                    onMoveUp: { move(row.id, by: -1) },
                    onMoveDown: { move(row.id, by: 1) }
                )
                .tag(row.id)
            }
            .onMove { source, destination in
                model.move(fromOffsets: source, toOffset: destination)
                commit()
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(height: listHeight)
        .onDeleteCommand { removeSelection() }
        .overlay {
            if model.rows.isEmpty {
                Text("No Extensions")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, buttonBarHeight)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    AddRemoveControlGroup(
                        addLabel: String(localized: "Add Extension…"),
                        removeLabel: String(localized: "Remove Extension"),
                        canRemove: !selection.isEmpty,
                        addIdentifier: "connection-extensions-add",
                        removeIdentifier: "connection-extensions-remove",
                        onAdd: { chooseFiles() },
                        onRemove: { removeSelection() }
                    )
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .background(.bar)
        }
    }

    private let rowHeight: CGFloat = 26
    private let buttonBarHeight: CGFloat = 32

    private var listHeight: CGFloat {
        let rows = CGFloat(max(model.rows.count, 2))
        return min(rows * rowHeight + buttonBarHeight + 8, 200)
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
        guard !model.matches(encoded: value) else { return }
        model = LoadableExtensionListModel(encoded: value)
        selection = selection.filter { id in model.rows.contains { $0.id == id } }
    }

    private func commit() {
        let encoded = model.encoded
        guard value != encoded else { return }
        value = encoded
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard model.rows.indices.contains(target) else { return }
        model.move(fromOffsets: IndexSet(integer: index), toOffset: offset > 0 ? target + 1 : target)
        commit()
    }

    private func removeSelection() {
        guard !selection.isEmpty else { return }
        selection = model.remove(selection)
        commit()
    }

    private func chooseFiles() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        let validator = LoadableExtensionPanelValidator()
        panel.title = String(localized: "Add Extension")
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Choose the SQLite extension libraries to load when this connection opens.")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.allowedContentTypes = LoadableExtensionPanelValidator.contentTypes
        panel.delegate = validator

        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(validator) {
                guard response == .OK else { return }
                selection = model.add(paths: panel.urls.map { $0.path(percentEncoded: false) })
                commit()
            }
        }
    }
}

private struct LoadableExtensionRowView: View {
    @Binding var path: String
    @Binding var entryPoint: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            issueIndicator
            TextField(
                String(localized: "Extension File"),
                text: $path,
                prompt: Text(verbatim: "/opt/homebrew/lib/mod_spatialite.dylib")
            )
            .labelsHidden()
            TextField(
                String(localized: "Entry Point"),
                text: $entryPoint,
                prompt: Text(String(localized: "Default entry point"))
            )
            .labelsHidden()
            .frame(width: 170)
            .help(String(localized: "The initialization function to call. Leave empty to use the one SQLite derives from the file name."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button(String(localized: "Move Up"), action: onMoveUp)
            Button(String(localized: "Move Down"), action: onMoveDown)
        }
    }

    @ViewBuilder
    private var issueIndicator: some View {
        if let issue = LoadableExtensionFileIssue.issue(forPath: path) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(issue.message)
                .accessibilityLabel(issue.message)
        }
    }
}

/// Refuses a file that is not a Mach-O library before it reaches the list. The panel's content types
/// only dim other files, and `.so` has no type of its own, so the choice is checked here as well.
private final class LoadableExtensionPanelValidator: NSObject, NSOpenSavePanelDelegate {
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
