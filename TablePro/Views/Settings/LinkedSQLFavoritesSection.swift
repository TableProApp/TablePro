//
//  LinkedSQLFavoritesSection.swift
//  TablePro
//

import AppKit
import SwiftUI

internal struct LinkedSQLFavoritesSection: View {
    @State private var folders: [LinkedSQLFolder] = LinkedSQLFolderStorage.shared.loadFolders()

    var body: some View {
        Section {
            if folders.isEmpty {
                Text("No linked SQL folders. Add a folder containing .sql files to load them as favorites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(folders) { folder in
                    folderRow(folder)
                }
            }

            Button {
                addFolder()
            } label: {
                Label("Add SQL Folder...", systemImage: "plus")
            }
        } header: {
            Text("Linked SQL Folders")
        } footer: {
            Text("Watched folders are scanned for .sql files. Add metadata via leading comments: `-- @name:`, `-- @keyword:`, `-- @description:`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func folderRow(_ folder: LinkedSQLFolder) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { folder.isEnabled },
                set: { newValue in
                    guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
                    folders[index].isEnabled = newValue
                    LinkedSQLFolderStorage.shared.saveFolders(folders)
                    SQLFolderWatcher.shared.reload()
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                    .font(.body)
                    .lineLimit(1)

                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(role: .destructive) {
                removeFolder(folder)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove Folder"))
            .accessibilityLabel(String(localized: "Remove folder"))
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder containing .sql files")

        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let path = PathPortability.contractHome(url.path)

            guard !self.folders.contains(where: { $0.path == path }) else { return }

            let folder = LinkedSQLFolder(path: path)
            LinkedSQLFolderStorage.shared.addFolder(folder)
            self.folders = LinkedSQLFolderStorage.shared.loadFolders()
            SQLFolderWatcher.shared.reload()
        }
    }

    private func removeFolder(_ folder: LinkedSQLFolder) {
        LinkedSQLFolderStorage.shared.removeFolder(folder)
        folders = LinkedSQLFolderStorage.shared.loadFolders()
        SQLFolderWatcher.shared.reload()
    }
}
