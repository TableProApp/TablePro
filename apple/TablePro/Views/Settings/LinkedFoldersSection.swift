import AppKit
import Combine
import SwiftUI
import TableProImport
import UniformTypeIdentifiers

@MainActor
internal final class LinkedFoldersModel: ObservableObject {
    @Published internal private(set) var folders: [LinkedFolder]

    private let storage: LinkedFolderStorage
    private let reloadWatcher: @MainActor () -> Void
    private var updates: AnyCancellable?

    internal init(
        storage: LinkedFolderStorage = .shared,
        updates: AnyPublisher<Void, Never> = AppEvents.shared.linkedFoldersDidUpdate.eraseToAnyPublisher(),
        reloadWatcher: @escaping @MainActor () -> Void = { LinkedFolderWatcher.shared.reload() }
    ) {
        self.storage = storage
        self.reloadWatcher = reloadWatcher
        folders = storage.loadFolders()
        // A folder added or removed anywhere else would otherwise leave the list as it was at load.
        self.updates = updates.sink { [weak self] _ in
            self?.reload()
        }
    }

    internal func reload() {
        apply(storage.loadFolders())
    }

    internal func add(_ url: URL) {
        let path = PathPortability.contractHome(url.path)
        let current = storage.loadFolders()
        guard !current.contains(where: { $0.path == path }) else {
            apply(current)
            return
        }
        storage.addFolder(LinkedFolder(path: path))
        apply(storage.loadFolders())
        reloadWatcher()
    }

    internal func remove(_ folder: LinkedFolder) {
        storage.removeFolder(folder)
        apply(storage.loadFolders())
        reloadWatcher()
    }

    internal func setEnabled(_ isEnabled: Bool, for folder: LinkedFolder) {
        var current = storage.loadFolders()
        guard let index = current.firstIndex(where: { $0.id == folder.id }),
              current[index].isEnabled != isEnabled else { return }
        current[index].isEnabled = isEnabled
        storage.saveFolders(current)
        apply(current)
        reloadWatcher()
    }

    private func apply(_ loaded: [LinkedFolder]) {
        guard loaded != folders else { return }
        folders = loaded
    }
}

internal struct LinkedFoldersPage: View {
    @EnvironmentObject private var model: LinkedFoldersModel
    @ObservedObject private var featureAccess = FeatureAccess.shared
    @ObservedObject private var watcher = LinkedFolderWatcher.shared
    @State private var isAddingFolder = false

    private var isLicensed: Bool {
        featureAccess.isAvailable(.linkedFolders)
    }

    internal var body: some View {
        Form {
            Section {
                if !isLicensed {
                    LicenseGateRow(feature: .linkedFolders)
                }

                if model.folders.isEmpty {
                    Text("No linked folders")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.folders) { folder in
                        LinkedFolderRow(
                            folder: folder,
                            status: folder.isEnabled ? watcher.folderStatuses[folder.id] : nil,
                            canTurnOn: isLicensed,
                            model: model
                        )
                    }
                }

                SettingsHelpRow(
                    "TablePro reads .tablepro files saved without a passphrase from these folders. Their connections appear read only in the sidebar."
                )
            } footer: {
                SettingsSectionActions {
                    Button(String(localized: "Add Folder…")) {
                        isAddingFolder = true
                    }
                    .disabled(!isLicensed)
                    .accessibilityIdentifier("linked-folders-add-button")
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isAddingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.add(url)
            }
        }
        .modifier(LinkedFolderDialogMessage())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.linkedFolders.pageIdentifier)
    }
}

private struct LinkedFolderRow: View {
    let folder: LinkedFolder
    let status: LinkedFolderStatus?
    let canTurnOn: Bool
    let model: LinkedFoldersModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { folder.isEnabled }, set: { model.setEnabled($0, for: folder) })) {
                    Text(verbatim: folder.name)
                }
                .toggleStyle(.switch)
                .labelsHidden()
                // A folder already on can always be turned off, licensed or not.
                .disabled(!canTurnOn && !folder.isEnabled)
                .accessibilityLabel(String(format: String(localized: "Watch %@"), folder.name))

                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(String(localized: "Actions"))
                .accessibilityLabel(String(format: String(localized: "Actions for %@"), folder.name))
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: folder.name)
                    .lineLimit(1)
                Text(verbatim: folder.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                if let status {
                    LinkedFolderStatusLines(status: status)
                        .font(.subheadline)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                Button(String(localized: "Show in Finder"), action: showInFinder)
                Button(String(localized: "Remove"), action: remove)
            }
        }
        .contextMenu {
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("linked-folder-row-\(folder.id.uuidString)")
    }

    @ViewBuilder private var actions: some View {
        Button(String(localized: "Show in Finder"), action: showInFinder)
        Divider()
        Button(String(localized: "Remove"), role: .destructive, action: remove)
    }

    private func remove() {
        model.remove(folder)
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.expandedPath)])
    }
}

private struct LinkedFolderStatusLines: View {
    let status: LinkedFolderStatus

    var body: some View {
        switch status.contents {
        case .missing:
            NoticeLabel(String(localized: "Folder not found"))
        case .unreadable:
            NoticeLabel(String(localized: "Can't read this folder"))
        case .connections(let count, let unreadableFiles):
            Text(verbatim: LinkedFolderStatusCopy.connections(count))
                .foregroundStyle(.secondary)
            if unreadableFiles > 0 {
                NoticeLabel(LinkedFolderStatusCopy.unreadableFiles(unreadableFiles))
            }
            if !status.isWatched {
                NoticeLabel(String(localized: "Not watching this folder for changes"))
            }
        }
    }
}

private struct LinkedFolderDialogMessage: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.fileDialogMessage(Text("Choose a folder to watch for .tablepro connection files"))
        } else {
            content
        }
    }
}

// Explicit singular and plural keys: see OperationCompletionCopy for why not inflection.
enum LinkedFolderStatusCopy {
    static func connections(_ count: Int) -> String {
        let template = count == 1 ? String(localized: "%lld connection") : String(localized: "%lld connections")
        return String(format: template, count)
    }

    static func unreadableFiles(_ count: Int) -> String {
        let template = count == 1
            ? String(localized: "%lld file couldn't be read")
            : String(localized: "%lld files couldn't be read")
        return String(format: template, count)
    }
}
