//
//  LinkedFoldersSection.swift
//  TablePro
//
//  Settings section for managing linked folders.
//  Linked folders are watched for .tablepro connection files.
//

import AppKit
import SwiftUI

struct LinkedFoldersSection: View {
    @State private var folders: [LinkedFolder] = LinkedFolderStorage.shared.loadFolders()

    private var isLicensed: Bool {
        LicenseManager.shared.isFeatureAvailable(.linkedFolders)
    }

    var body: some View {
        Section {
            if folders.isEmpty {
                Text("No linked folders. Add a folder to watch for shared connection files.")
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
                Label("Add Folder...", systemImage: "plus")
            }
            .disabled(!isLicensed)
        } header: {
            HStack(spacing: 6) {
                Text("Linked Folders")
                if !isLicensed {
                    ProBadge()
                }
            }
        } footer: {
            Text("Watched folders are scanned for .tablepro files. Connections appear read only in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Folder Row

    private func folderRow(_ folder: LinkedFolder) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { folder.isEnabled },
                set: { newValue in
                    guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
                    folders[index].isEnabled = newValue
                    LinkedFolderStorage.shared.saveFolders(folders)
                    LinkedFolderWatcher.shared.reload()
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

    // MARK: - Actions

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder to watch for .tablepro connection files")

        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let path = PathPortability.contractHome(url.path)

            guard !self.folders.contains(where: { $0.path == path }) else { return }

            let folder = LinkedFolder(path: path)
            LinkedFolderStorage.shared.addFolder(folder)
            self.folders = LinkedFolderStorage.shared.loadFolders()
            LinkedFolderWatcher.shared.reload()
        }
    }

    private func removeFolder(_ folder: LinkedFolder) {
        LinkedFolderStorage.shared.removeFolder(folder)
        folders = LinkedFolderStorage.shared.loadFolders()
        LinkedFolderWatcher.shared.reload()
    }
}
