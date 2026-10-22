//
//  AttachedDatabaseListEditor.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Built like the Extensions list below it, so the two lists in Options behave the same.
struct AttachedDatabaseListEditor: View {
    @Binding var value: String
    let databaseType: DatabaseType

    @State private var model = AttachedDatabaseListModel(encoded: "")
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            list
            if model.isUnreadable {
                Label(
                    String(localized: "The saved list could not be read. Adding a database replaces it."),
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
                AttachedDatabaseRowView(
                    name: nameBinding(for: row.id),
                    path: pathBinding(for: row.id),
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
                Text("No Attached Databases")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, buttonBarHeight)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    AddRemoveControlGroup(
                        addLabel: String(localized: "Attach Database…"),
                        removeLabel: String(localized: "Remove Attached Database"),
                        canRemove: !selection.isEmpty,
                        addIdentifier: "connection-attached-databases-add",
                        removeIdentifier: "connection-attached-databases-remove",
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
        guard !model.matches(encoded: value) else { return }
        model = AttachedDatabaseListModel(encoded: value)
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
        let rule = DatabaseFileBrowseRule(type: databaseType, extensions: PluginManager.shared.fileExtensions(for: databaseType))
        let filter = PanelEnableFilter(isEnabled: rule.isEnabled)
        panel.title = String(localized: "Attach Database")
        panel.prompt = String(localized: "Attach")
        panel.message = String(localized: "Choose the database files to attach each time this connection opens.")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.delegate = filter

        panel.beginSheetModal(for: window) { response in
            withExtendedLifetime(filter) {
                guard response == .OK else { return }
                selection = model.add(paths: panel.urls.map { $0.path(percentEncoded: false) })
                commit()
            }
        }
    }
}

private struct AttachedDatabaseRowView: View {
    @Binding var name: String
    @Binding var path: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            issueIndicator
            TextField(String(localized: "Name"), text: $name, prompt: Text(String(localized: "Name")))
                .labelsHidden()
                .frame(width: 120)
                .help(String(localized: "The name a statement uses for this database, as in name.table."))
            TextField(
                String(localized: "Database File"),
                text: $path,
                prompt: Text(verbatim: "/path/to/database.db")
            )
            .labelsHidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button(String(localized: "Move Up"), action: onMoveUp)
            Button(String(localized: "Move Down"), action: onMoveDown)
        }
    }

    @ViewBuilder
    private var issueIndicator: some View {
        if let issue = AttachedDatabaseFileIssue.issue(forPath: path) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(issue.message)
                .accessibilityLabel(issue.message)
        }
    }
}
