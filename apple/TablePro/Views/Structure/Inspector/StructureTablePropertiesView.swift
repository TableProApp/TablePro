//
//  StructureTablePropertiesView.swift
//  TablePro
//

import SwiftUI

// What the inspector shows for a table with no definition selected: its comment, its default character set and
// AUTO_INCREMENT counter, and the read-only statistics.
struct StructureTablePropertiesView: View {
    @ObservedObject var session: StructureEditingSession
    @ObservedObject var changeManager: StructureChangeManager
    let tableMetadata: TableMetadata?

    // A session-bound table belongs to one connection's session, so its definition is not this window's to change.
    private var isReadOnly: Bool {
        session.editor.isReadOnly || session.isSessionBound
    }

    var body: some View {
        let offersComment = session.offersTableComment
        let offersOptions = session.offersTableOptionsTab
        if !offersComment, !offersOptions, tableMetadata == nil {
            UnavailableStateView(
                String(localized: "No Selection"),
                systemImage: TrailingPaneSurface.inspector.symbolName,
                description: Text(String(localized: "Select a definition to edit it"))
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if offersComment {
                        StructureTableCommentSection(
                            session: session, changeManager: changeManager, isReadOnly: isReadOnly
                        )
                    }
                    if offersOptions {
                        StructureTableOptionsSection(
                            session: session, changeManager: changeManager, isReadOnly: isReadOnly
                        )
                    }
                    if let tableMetadata {
                        TableInfoSections(metadata: tableMetadata, includesComment: false)
                    }
                }
                .padding(.horizontal, InspectorMetrics.horizontalInset)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.subheadline)
            .controlSize(.small)
        }
    }
}

// MARK: - Comment

private struct StructureTableCommentSection: View {
    @ObservedObject var session: StructureEditingSession
    @ObservedObject var changeManager: StructureChangeManager
    let isReadOnly: Bool

    @FocusState private var isFocused: Bool

    private var field: StructureTableCommentPolicy.Field? {
        StructureTableCommentPolicy.resolve(
            objectKind: session.objectKind,
            support: DatabaseObjectToolEligibility.Support.of(DatabaseManager.shared.driver(for: session.connection.id)),
            isReadOnly: isReadOnly,
            load: session.tableComment.erased,
            isSaving: changeManager.isHeldForSave || session.editor.isAwaitingBaseline
        )
    }

    // One model write per keystroke, so a save from the keyboard never misses what is still in the field.
    private var text: Binding<String> {
        Binding(
            get: { changeManager.tableComment.text },
            set: { changeManager.stageTableComment($0) }
        )
    }

    var body: some View {
        if let field {
            VStack(alignment: .leading, spacing: 6) {
                StructureInspectorSectionHeader(title: String(localized: "Table"))
                VStack(alignment: .leading, spacing: 10) {
                    StructureInspectorRow(
                            label: String(localized: "Comment"),
                            isModified: changeManager.tableComment.hasChanges
                        ) {
                        TextField(field.placeholder, text: text, axis: .vertical)
                            .lineLimit(2...6)
                            .textFieldStyle(.squareBorder)
                            .disabled(!field.isEditable)
                            .focused($isFocused)
                            .onSubmit { changeManager.endTableCommentRun() }
                            .help(field.unavailableReason ?? "")
                            .accessibilityLabel(String(localized: "Comment"))
                            .accessibilityIdentifier("structure-table-comment")
                    }
                }
            }
            .onChange(of: isFocused) { focused in
                guard !focused else { return }
                changeManager.endTableCommentRun()
            }
            .onDisappear { changeManager.endTableCommentRun() }
        }
    }
}

// MARK: - Options

// Every edit is one whole-value write to the change manager, so the coupled character set and collation pick
// lands as one staged change and one undo step.
private struct StructureTableOptionsSection: View {
    @ObservedObject var session: StructureEditingSession
    @ObservedObject var changeManager: StructureChangeManager
    let isReadOnly: Bool

    @State private var counterText = ""
    @FocusState private var isCounterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StructureInspectorSectionHeader(title: String(localized: "Options"))
            if let options = displayedOptions {
                form(options)
            } else {
                stateView
            }
        }
        .task { await session.readTableOptionsCatalog() }
        .onAppear { counterText = Self.text(displayedCounter) }
        .onChange(of: displayedCounter) { counter in
            guard !isCounterFocused else { return }
            counterText = Self.text(counter)
        }
        // Text that is not a valid counter stays in the field beside its error, since it holds Save until fixed.
        .onChange(of: isCounterFocused) { focused in
            guard !focused, entry(counterText)?.message == nil else { return }
            counterText = Self.text(displayedCounter)
        }
    }

    // MARK: State

    private var draft: TableOptions? { changeManager.tableOptions.current }

    // A read that landed while edits were staged has not become the baseline yet, so it shows read-only.
    private var displayedOptions: TableOptions? {
        draft ?? (session.tableOptions.value ?? nil)
    }

    private var isCounterConfirmed: Bool {
        session.autoIncrementRead == .confirmed && changeManager.tableOptions.isAutoIncrementConfirmed
    }

    // An unconfirmed counter may be one the server moved past; a read deferred behind staged edits shows read-only.
    private var displayedCounter: UInt64? {
        guard session.autoIncrementRead == .confirmed else { return nil }
        guard changeManager.tableOptions.isAutoIncrementConfirmed else { return session.loadedTableOptions?.autoIncrement }
        return displayedOptions?.autoIncrement
    }

    // The draft's column, not the loaded one: the counter is set after the column work in the same save.
    private var autoIncrementMaximum: UInt64? {
        changeManager.autoIncrementColumn.map { AutoIncrementEntry.maximum(for: $0) }
    }

    private var editability: StructureTableOptionsPolicy.Editability {
        StructureTableOptionsPolicy.resolve(
            hasBaseline: draft != nil,
            isReadOnly: isReadOnly,
            isSaving: changeManager.isHeldForSave || session.editor.isAwaitingBaseline
        )
    }

    private var catalog: TableOptionsCatalog? {
        guard case .loaded(let catalog) = session.tableOptionsCatalog else { return nil }
        return catalog
    }

    private func entry(_ text: String) -> AutoIncrementEntry? {
        autoIncrementMaximum.map {
            AutoIncrementEntry(text, maximum: $0, original: changeManager.tableOptions.original?.autoIncrement)
        }
    }

    private static func text(_ counter: UInt64?) -> String {
        counter.map { String($0) } ?? ""
    }

    // A retried read lands only in the session; the baseline moves unless edits are staged.
    private func retryOptions() {
        Task {
            await session.readTableOptions()
            session.rebaselineUnlessEdited()
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch session.tableOptions {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(String(localized: "Couldn't read the table options"), systemImage: "exclamationmark.triangle")
                RevealedTextView(message)
                    .foregroundStyle(.secondary)
                Button(String(localized: "Try Again"), action: retryOptions)
                    .accessibilityIdentifier("structure-options-retry")
            }
        case .loaded:
            StructureInspectorFootnote(text: String(localized: "This table has no options to change."))
        }
    }

    // MARK: Form

    private func form(_ options: TableOptions) -> some View {
        let editability = self.editability
        let original = changeManager.tableOptions.original
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                StructureInspectorRow(
                        label: String(localized: "Character Set"),
                        isModified: draft != nil && options.characterSet != original?.characterSet
                    ) {
                    Picker(String(localized: "Character Set"), selection: characterSetBinding) {
                        if options.characterSet == nil {
                            Text(String(localized: "Unknown")).tag(String?.none)
                        }
                        ForEach(TableOptionsForm.characterSets(in: catalog, keeping: options.characterSet), id: \.self) {
                            Text($0).tag(Optional($0))
                        }
                    }
                    .labelsHidden()
                    .disabled(!editability.isEditable || catalog == nil)
                    .accessibilityIdentifier("structure-options-charset")
                }

                StructureInspectorRow(
                        label: String(localized: "Collation"),
                        isModified: draft != nil && options.collation != original?.collation
                    ) {
                    Picker(String(localized: "Collation"), selection: collationBinding) {
                        if options.collation == nil {
                            Text(String(localized: "Unknown")).tag(String?.none)
                        }
                        ForEach(collationChoices(options)) { choice in
                            Text(choice.title).tag(Optional(choice.name))
                        }
                    }
                    .labelsHidden()
                    .disabled(!editability.isEditable || catalog == nil)
                    .accessibilityIdentifier("structure-options-collation")
                }

                Group {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(String(localized: "Convert existing columns"), isOn: convertBinding)
                            .toggleStyle(.checkbox)
                            .fontWeight(options.convertsColumns ? .semibold : .regular)
                            .disabled(!editability.isEditable)
                            .accessibilityIdentifier("structure-options-convert")
                        StructureInspectorFootnote(text: Self.convertFootnote(options.convertsColumns))
                    }
                }

                catalogStatusRow

                if let maximum = autoIncrementMaximum {
                    counterRows(maximum: maximum, isEditable: editability.isEditable, original: original)
                }
            }

            if let reason = editability.unavailableReason, !changeManager.isHeldForSave {
                Label(reason, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("structure-options-unavailable-note")
            }
        }
    }

    private static func convertFootnote(_ converts: Bool) -> String {
        guard converts else {
            return String(localized: "Applies to columns added later. Existing columns keep their character set.")
        }
        return String(
            localized: "Rewrites every text column to this character set. TEXT can grow to MEDIUMTEXT, and the table is copied while it runs."
        )
    }

    private func collationChoices(_ options: TableOptions) -> [TableOptionsForm.Choice] {
        TableOptionsForm.collations(in: catalog, characterSet: options.characterSet, keeping: options.collation)
    }

    @ViewBuilder
    private var catalogStatusRow: some View {
        switch session.tableOptionsCatalog {
        case .idle, .loading:
            Group {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    StructureInspectorFootnote(text: String(localized: "Reading the server's character sets…"))
                }
            }
        case .failed:
            Group {
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(localized: "Couldn't read the server's character sets."), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Try Again")) {
                        Task { await session.readTableOptionsCatalog() }
                    }
                    .accessibilityIdentifier("structure-options-catalog-retry")
                }
            }
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counterRows(maximum: UInt64, isEditable: Bool, original: TableOptions?) -> some View {
        StructureInspectorRow(
                label: String(localized: "Next Auto Increment"),
                isModified: draft != nil && draft?.autoIncrement != original?.autoIncrement
            ) {
            TextField(String(localized: "Next Auto Increment"), text: counterBinding)
                .labelsHidden()
                .textFieldStyle(.squareBorder)
                .focused($isCounterFocused)
                .disabled(!isEditable || !isCounterConfirmed)
                .accessibilityLabel(String(localized: "Next Auto Increment"))
                .accessibilityIdentifier("structure-options-auto-increment")
        }
        // The server raises a value below the next free one, so a saved counter is read back, never shown as typed.
        switch session.autoIncrementRead {
        case .rereading:
            Group {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    StructureInspectorFootnote(text: String(localized: "Reading the saved value…"))
                }
            }
        case .unconfirmed:
            Group {
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(localized: "Couldn't read the saved value."), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Try Again"), action: retryOptions)
                        .accessibilityIdentifier("structure-options-auto-increment-retry")
                }
            }
        case .confirmed:
            EmptyView()
        }
        if let message = AutoIncrementEntry(counterText, maximum: maximum, original: original?.autoIncrement).message {
            Group {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("structure-options-auto-increment-error")
            }
        }
        Group {
            StructureInspectorFootnote(text: String(localized: "A value at or below the highest existing ID becomes that ID plus one."))
        }
    }

    // MARK: Bindings

    private var characterSetBinding: Binding<String?> {
        Binding(
            get: { displayedOptions?.characterSet },
            set: { name in
                guard let name, let current = draft, name != current.characterSet else { return }
                changeManager.stageTableOptions(TableOptionsForm.selectingCharacterSet(name, in: current, catalog: catalog))
            }
        )
    }

    private var collationBinding: Binding<String?> {
        Binding(
            get: { displayedOptions?.collation },
            set: { name in
                guard let name, var next = draft, name != next.collation else { return }
                next.collation = name
                changeManager.stageTableOptions(next)
            }
        )
    }

    private var convertBinding: Binding<Bool> {
        Binding(
            get: { displayedOptions?.convertsColumns ?? false },
            set: { converts in
                guard var next = draft, converts != next.convertsColumns else { return }
                next.convertsColumns = converts
                changeManager.stageTableOptions(next)
            }
        )
    }

    // Staged per keystroke, as the comment is, so a save from the keyboard never misses a value still in the field.
    // Text that is not a valid counter stages the loaded one and holds Save until it is fixed or cleared.
    private var counterBinding: Binding<String> {
        Binding(
            get: { counterText },
            set: { text in
                counterText = text
                guard var next = draft, let entry = entry(text) else { return }
                switch entry {
                case .value(let value):
                    next.autoIncrement = value
                case .empty, .invalid:
                    next.autoIncrement = changeManager.tableOptions.original?.autoIncrement
                }
                changeManager.noteAutoIncrementEntry(invalid: entry.message)
                guard next != draft else { return }
                changeManager.stageTableOptions(next)
            }
        )
    }
}
