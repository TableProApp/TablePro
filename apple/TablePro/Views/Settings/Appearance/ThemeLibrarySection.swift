import AppKit
import SwiftUI
import TableProTheme
import UniformTypeIdentifiers

// A context menu acts on the row under the pointer, which is not always the selected one.
internal struct ThemeLibrarySection: View {
    @ObservedObject private var model: ThemeLibraryModel

    @Environment(\.undoManager) private var undoManager

    @State private var selection: ThemeLibraryItem?
    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var pendingTrash: ThemeTrashConfirmation?
    @State private var isImporting = false
    @State private var exporting: ExportRequest?
    @FocusState private var isRenameFieldFocused: Bool

    private struct ExportRequest {
        let document: ThemeFileDocument
        let fileName: String
    }

    private static let minimumListHeight: CGFloat = 160
    // A two-line theme row. The table sizes a row it has not measured at this estimate, and an
    // accessibility read makes it drop and remeasure off-screen rows, so any other value moves the rows.
    private static let rowHeight: CGFloat = 42

    internal init(model: ThemeLibraryModel) {
        self._model = ObservedObject(wrappedValue: model)
    }

    internal var body: some View {
        SettingsFullPageList {
            list
        } bar: {
            bar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsPage.manageThemes.pageIdentifier)
        .alert(
            model.alert?.title ?? "",
            isPresented: isPresented($model.alert),
            presenting: model.alert
        ) { _ in
            Button(String(localized: "OK")) {}
        } message: { alert in
            Text(alert.message)
        }
        .alert(
            pendingTrash?.title ?? "",
            isPresented: isPresented($pendingTrash),
            presenting: pendingTrash
        ) { confirmation in
            Button(String(localized: "Move to Trash"), role: .destructive) {
                trash(confirmation.item)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            importThemes(urls)
        }
        .fileExporter(
            isPresented: isPresented($exporting),
            document: exporting?.document,
            contentType: .json,
            defaultFilename: exporting?.fileName
        ) { _ in }
    }

    // The user's own themes come first: the built-ins above them would push the rows a person
    // creates, renames and trashes out of sight.
    private var list: some View {
        let inUse = model.inUseThemeIds
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                Section(String(localized: "Custom")) {
                    if model.customThemes.isEmpty {
                        Text("Click + to add a theme, or drop a TablePro or VS Code theme file here.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("appearance-themes-custom-empty")
                    }
                    ForEach(model.customThemes) { theme in
                        themeRow(theme, isInUse: inUse.contains(theme.id))
                            .tag(ThemeLibraryItem.theme(theme.id))
                            .id(ThemeLibraryItem.theme(theme.id))
                    }
                }

                if !model.notLoaded.isEmpty {
                    Section(String(localized: "Couldn't Load")) {
                        ForEach(model.notLoaded) { record in
                            notLoadedRow(record)
                                .tag(ThemeLibraryItem.notLoaded(path: record.path))
                                .id(ThemeLibraryItem.notLoaded(path: record.path))
                        }
                    }
                }

                Section(String(localized: "Built-in")) {
                    ForEach(model.builtInThemes) { theme in
                        themeRow(theme, isInUse: inUse.contains(theme.id))
                            .tag(ThemeLibraryItem.theme(theme.id))
                            .id(ThemeLibraryItem.theme(theme.id))
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .contextMenu(forSelectionType: ThemeLibraryItem.self) { items in
                if let item = items.first {
                    menuItems(for: item, dimsUnavailable: false)
                } else {
                    emptyAreaMenu
                }
            } primaryAction: { items in
                guard case let .theme(id) = items.first else { return }
                model.edit(id)
            }
            .onDeleteCommand {
                if model.canTrash(selection) {
                    requestTrash(selection)
                } else {
                    NSSound.beep()
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                importThemes(files)
                return true
            }
            .onChange(of: selection) { item in
                guard let item else { return }
                proxy.scrollTo(item)
            }
            .frame(minHeight: Self.minimumListHeight, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("appearance-themes-list")
        }
    }

    @ViewBuilder
    private func themeRow(_ theme: ThemeDefinition, isInUse: Bool) -> some View {
        if renamingId == theme.id {
            renameField(for: theme)
        } else {
            // No combined element: the UI tests find a row by its name's text.
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name)
                    .lineLimit(1)
                Text(ThemeLibraryModel.rowSubtitle(theme.appearance, isInUse: isInUse))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .onDrag { model.dragItemProvider(for: theme.id) }
        }
    }

    private func renameField(for theme: ThemeDefinition) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(String(localized: "Name"), text: $renameText)
                .labelsHidden()
                .focused($isRenameFieldFocused)
                .onSubmit { commitRename(theme.id) }
                .onExitCommand(perform: cancelRename)
                .onAppear { isRenameFieldFocused = true }
                .onChange(of: isRenameFieldFocused) { isFocused in
                    if !isFocused { commitRename(theme.id) }
                }
                .accessibilityIdentifier("appearance-theme-rename-field")
            if let renameError {
                NoticeLabel(renameError, severity: .error)
                    .font(.subheadline)
                    .accessibilityIdentifier("appearance-theme-rename-error")
            }
        }
        .padding(.vertical, 2)
    }

    private func notLoadedRow(_ record: RejectedThemeRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(record.fileName)
                .lineLimit(1)
            Text(record.reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .help(record.reason)
    }

    private var bar: some View {
        SettingsListBar(
            addLabel: String(localized: "Add Theme"),
            removeLabel: String(localized: "Move to Trash"),
            canRemove: model.canTrash(selection),
            addIdentifier: "appearance-theme-add",
            removeIdentifier: "appearance-theme-remove",
            addMenu: { addMenuItems },
            onRemove: { requestTrash(selection) },
            actionsLabel: String(localized: "Theme Actions"),
            actionsIdentifier: "appearance-theme-actions",
            actions: {
                menuItems(for: selection, dimsUnavailable: true)
                Divider()
                showThemesFolderButton
            }
        )
    }

    @ViewBuilder
    private var addMenuItems: some View {
        newThemeMenu
        Divider()
        importButton
    }

    @ViewBuilder
    private var emptyAreaMenu: some View {
        newThemeMenu
        importButton
        Divider()
        showThemesFolderButton
    }

    private var newThemeMenu: some View {
        Menu(String(localized: "New Theme Based On")) {
            ForEach(model.builtInThemes) { theme in
                Button(theme.name) { createTheme(basedOn: theme.id) }
            }
            if !model.customThemes.isEmpty {
                Divider()
                ForEach(model.customThemes) { theme in
                    Button(theme.name) { createTheme(basedOn: theme.id) }
                }
            }
        }
    }

    private var importButton: some View {
        Button(String(localized: "Import…")) { isImporting = true }
    }

    private var showThemesFolderButton: some View {
        Button(String(localized: "Show Themes Folder in Finder")) { model.revealThemesFolder() }
    }

    // The context menu leaves out what does not apply; the pull-down dims it.
    private func menuItems(for item: ThemeLibraryItem?, dimsUnavailable: Bool) -> some View {
        let entries = model.menuEntries(for: item).filter { dimsUnavailable || $0.isEnabled }
        return ForEach(Array(entries.enumerated()), id: \.element.action) { index, entry in
            if entry.startsGroup, index > 0 {
                Divider()
            }
            if entry.action == .rename, !dimsUnavailable {
                RenameButton()
                    .renameAction { perform(.rename, on: item) }
            } else {
                Button(entry.action.title) { perform(entry.action, on: item) }
                    .disabled(!entry.isEnabled)
            }
        }
    }

    private func perform(_ action: ThemeLibraryAction, on item: ThemeLibraryItem?) {
        switch action {
        case .edit, .showInEditor:
            guard case let .theme(id) = item else { return }
            model.edit(id)
        case .duplicate:
            guard case let .theme(id) = item else { return }
            duplicate(id)
        case .rename:
            guard let theme = model.theme(for: item) else { return }
            beginRename(theme)
        case .export:
            guard case let .theme(id) = item else { return }
            export(id)
        case let .use(slot):
            guard case let .theme(id) = item else { return }
            model.use(id, for: slot)
        case .showInFinder:
            model.revealInFinder(item)
        case .tryAgain:
            model.retryLoading()
        case .moveToTrash:
            requestTrash(item)
        }
    }

    private func duplicate(_ id: String) {
        guard let copy = model.duplicate(id, undoManager: undoManager) else { return }
        selection = .theme(copy.id)
    }

    private func createTheme(basedOn id: String) {
        guard let copy = model.createTheme(basedOn: id, undoManager: undoManager) else { return }
        selection = .theme(copy.id)
    }

    private func importThemes(_ urls: [URL]) {
        let report = model.importThemes(from: urls, undoManager: undoManager)
        if let last = report.imported.last {
            selection = .theme(last.id)
        }
    }

    private func export(_ id: String) {
        guard let theme = model.catalog.storedTheme(id: id), let document = model.exportDocument(for: id) else { return }
        exporting = ExportRequest(document: document, fileName: ThemeLibraryModel.exportFileName(for: theme))
    }

    private func beginRename(_ theme: ThemeDefinition) {
        guard theme.isEditable else { return }
        selection = .theme(theme.id)
        renameText = model.nameForRenaming(theme.id) ?? theme.name
        renameError = nil
        renamingId = theme.id
    }

    // A taken name keeps the field open with the reason, the way Finder refuses one.
    private func commitRename(_ id: String) {
        guard renamingId == id else { return }
        switch model.rename(id, to: renameText, undoManager: undoManager) {
        case .renamed, .unchanged:
            endRename()
        case let .rejected(message):
            renameError = message
            NSSound.beep()
            isRenameFieldFocused = true
        }
    }

    private func cancelRename() {
        endRename()
    }

    private func endRename() {
        renamingId = nil
        renameError = nil
        isRenameFieldFocused = false
    }

    private func requestTrash(_ item: ThemeLibraryItem?) {
        guard let item, model.canTrash(item) else { return }
        if let confirmation = model.trashConfirmation(for: item) {
            pendingTrash = confirmation
        } else {
            trash(item)
        }
    }

    private func trash(_ item: ThemeLibraryItem) {
        guard model.moveToTrash(item, undoManager: undoManager) else { return }
        if selection == item {
            selection = nil
        }
    }

    private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }
}
