import AppKit
import SwiftUI
import TableProTheme
import UniformTypeIdentifiers

/// Every theme on this Mac in one list: the built-ins, the user's own, and the files that did not
/// load. The add and remove pair and the action pull-down sit under it the way macOS puts them under
/// a list. A context menu acts on the row under the pointer, which is not always the selected one.
internal struct ThemeLibrarySection: View {
    @StateObject private var model = ThemeLibraryModel(
        catalog: .shared,
        selection: AppSettingsManager.shared,
        editors: ThemeEditorWindows.shared
    )

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

    // Fits the Settings pane's default 500 pt height under the two sections above it.
    private static let listHeight: CGFloat = 176

    internal var body: some View {
        Section {
            list
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
        } header: {
            Text("Themes")
        }
    }

    // MARK: - List

    /// The user's own themes come first: fourteen built-ins above them would push the rows a person
    /// creates, renames and trashes out of sight.
    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section(String(localized: "Custom")) {
                    if model.customThemes.isEmpty {
                        Text("Duplicate a theme or import one to customize colors.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("appearance-themes-custom-empty")
                    }
                    ForEach(model.customThemes) { theme in
                        themeRow(theme)
                            .tag(ThemeLibraryItem.theme(theme.id))
                            .id(ThemeLibraryItem.theme(theme.id))
                    }
                }

                if !model.notLoaded.isEmpty {
                    Section(String(localized: "Not Loaded")) {
                        ForEach(model.notLoaded) { record in
                            notLoadedRow(record)
                                .tag(ThemeLibraryItem.notLoaded(path: record.path))
                                .id(ThemeLibraryItem.notLoaded(path: record.path))
                        }
                    }
                }

                Section(String(localized: "Built-in")) {
                    ForEach(model.builtInThemes) { theme in
                        themeRow(theme)
                            .tag(ThemeLibraryItem.theme(theme.id))
                            .id(ThemeLibraryItem.theme(theme.id))
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: Self.listHeight)
            .contextMenu(forSelectionType: ThemeLibraryItem.self) { items in
                rowMenu(for: items.first)
            } primaryAction: { items in
                guard case let .theme(id) = items.first else { return }
                model.edit(id)
            }
            .onDeleteCommand { requestTrash(selection) }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                importThemes(files)
                return true
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer
            }
            .onChange(of: selection) { item in
                guard let item else { return }
                proxy.scrollTo(item)
            }
        }
    }

    @ViewBuilder
    private func themeRow(_ theme: ThemeDefinition) -> some View {
        if renamingId == theme.id {
            renameField(for: theme)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                Text(theme.name)
                    .lineLimit(1)
                Text(ThemeLibraryModel.appearanceLabel(theme.appearance))
                    .font(.caption)
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
                Text(renameError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .help(record.reason)
    }

    /// A contextual menu leaves out what does not apply; the pull-down below dims it instead.
    @ViewBuilder
    private func rowMenu(for item: ThemeLibraryItem?) -> some View {
        if let theme = model.theme(for: item) {
            if theme.isEditable {
                Button(String(localized: "Edit…")) { model.edit(theme.id) }
            }
            Button(String(localized: "Duplicate")) { duplicate(theme.id) }
            if theme.isEditable {
                RenameButton()
                    .renameAction { beginRename(theme) }
            }
            Button(String(localized: "Export…")) { export(theme.id) }
            if let slot = model.availableSlot(for: theme) {
                Button(useTitle(for: slot)) { model.use(theme.id, for: slot) }
            }
            if theme.isEditable {
                Button(String(localized: "Show in Finder")) { model.revealInFinder(item) }
                Divider()
                Button(String(localized: "Move to Trash")) { requestTrash(item) }
            }
        } else if let item, model.record(for: item) != nil {
            Button(String(localized: "Show in Finder")) { model.revealInFinder(item) }
            Button(String(localized: "Try Again")) { model.retryLoading() }
            Divider()
            Button(String(localized: "Move to Trash")) { requestTrash(item) }
        }
    }

    private func useTitle(for slot: ThemeAppearance) -> String {
        switch slot {
        case .light: return String(localized: "Use for Light Appearance")
        case .dark: return String(localized: "Use for Dark Appearance")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ControlGroup {
                    addMenu

                    Button {
                        requestTrash(selection)
                    } label: {
                        Label(String(localized: "Move to Trash"), systemImage: "minus")
                            .labelStyle(.iconOnly)
                    }
                    .help(String(localized: "Move to Trash"))
                    .accessibilityLabel(String(localized: "Move to Trash"))
                    .accessibilityIdentifier("appearance-theme-remove")
                    .disabled(!model.canTrash(selection))

                    actionsMenu
                }
                .controlGroupStyle(.navigation)
                .controlSize(.small)
                .fixedSize()

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .background(.bar)
    }

    /// An icon-only `Menu` is named only through `.contain` plus a label on the menu itself; a
    /// label inside its label closure leaves VoiceOver reading "More", or nothing on CI.
    private var addMenu: some View {
        Menu {
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
            Divider()
            Button(String(localized: "Import…")) { isImporting = true }
        } label: {
            Label(String(localized: "Add Theme"), systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Add Theme"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Add Theme"))
        .accessibilityIdentifier("appearance-theme-add")
    }

    private var actionsMenu: some View {
        let theme = model.theme(for: selection)
        return Menu {
            Button(String(localized: "Edit…")) {
                if let theme { model.edit(theme.id) }
            }
            .disabled(theme == nil)
            Button(String(localized: "Duplicate")) {
                if let theme { duplicate(theme.id) }
            }
            .disabled(theme == nil)
            Button(String(localized: "Rename")) {
                if let theme { beginRename(theme) }
            }
            .disabled(theme?.isEditable != true)
            Button(String(localized: "Export…")) {
                if let theme { export(theme.id) }
            }
            .disabled(theme == nil)
            Divider()
            Button(String(localized: "Show in Finder")) { model.revealInFinder(selection) }
        } label: {
            Label(String(localized: "Theme Actions"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(String(localized: "Theme Actions"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Theme Actions"))
        .accessibilityIdentifier("appearance-theme-actions")
    }

    // MARK: - Actions

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

    /// A taken name keeps the field open with the reason, the way Finder refuses one.
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
