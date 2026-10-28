//
//  TableOptionsView.swift
//  TablePro
//

import SwiftUI

// The Structure tab's Options sub-tab: the table's default character set and collation, and its AUTO_INCREMENT
// counter. Every edit is one whole-value write to the change manager, so the coupled charset and collation pick
// lands as one staged change and one undo step.
internal struct TableOptionsView: View {
    @ObservedObject var session: StructureEditingSession
    @ObservedObject var changeManager: StructureChangeManager
    let isReadOnly: Bool
    // The draft AUTO_INCREMENT column's largest value, nil when the table has none.
    let autoIncrementMaximum: UInt64?
    let onRetry: () -> Void
    let onRetryCatalog: () -> Void

    @State private var counterText = ""
    @FocusState private var isCounterFocused: Bool

    var body: some View {
        Group {
            if let options = displayedOptions {
                form(options)
            } else {
                stateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { syncCounterText() }
        .onChange(of: displayedCounter) { _ in
            guard !isCounterFocused else { return }
            syncCounterText()
        }
        .onChange(of: isCounterFocused) { isFocused in
            if !isFocused { syncCounterText() }
        }
    }

    // MARK: - State

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

    private var editability: StructureTableOptionsPolicy.Editability {
        StructureTableOptionsPolicy.resolve(
            hasBaseline: draft != nil,
            isReadOnly: isReadOnly,
            isSaving: changeManager.isHeldForSave
        )
    }

    private var catalog: TableOptionsCatalog? {
        guard case .loaded(let catalog) = session.tableOptionsCatalog else { return nil }
        return catalog
    }

    @ViewBuilder
    private var stateView: some View {
        switch session.tableOptions {
        case .idle, .loading:
            ProgressView()
                .controlSize(.small)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Couldn't read the table options")
                RevealedTextView(message)
                    .foregroundStyle(.secondary)
                Button("Try Again", action: onRetry)
                    .accessibilityIdentifier("structure-options-retry")
            }
            .padding()
        case .loaded:
            Text("This table has no options to change.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Form

    private func form(_ options: TableOptions) -> some View {
        let editability = self.editability
        return Form {
            Section {
                Picker("Character Set", selection: characterSetBinding) {
                    if options.characterSet == nil {
                        Text("Unknown").tag(String?.none)
                    }
                    ForEach(TableOptionsForm.characterSets(in: catalog, keeping: options.characterSet), id: \.self) {
                        Text($0).tag(Optional($0))
                    }
                }
                .disabled(!editability.isEditable || catalog == nil)
                .accessibilityIdentifier("structure-options-charset")

                Picker("Collation", selection: collationBinding) {
                    if options.collation == nil {
                        Text("Unknown").tag(String?.none)
                    }
                    ForEach(collationChoices(options)) { choice in
                        Text(choice.title).tag(Optional(choice.name))
                    }
                }
                .disabled(!editability.isEditable || catalog == nil)
                .accessibilityIdentifier("structure-options-collation")

                Toggle("Convert existing columns", isOn: convertBinding)
                    .disabled(!editability.isEditable)
                    .accessibilityIdentifier("structure-options-convert")

                catalogStatusRow
            } footer: {
                if options.convertsColumns {
                    Text("Rewrites every text column to this character set. TEXT can grow to MEDIUMTEXT, and the table is copied while it runs.")
                } else {
                    Text("Applies to columns added later. Existing columns keep their character set.")
                }
            }

            if let maximum = autoIncrementMaximum {
                counterSection(maximum: maximum, isEditable: editability.isEditable)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let reason = editability.unavailableReason, !changeManager.isHeldForSave {
                StructureTabNoteView(systemImage: "lock", text: reason, identifier: "structure-options-unavailable-note")
            }
        }
    }

    private func collationChoices(_ options: TableOptions) -> [TableOptionsForm.Choice] {
        TableOptionsForm.collations(in: catalog, characterSet: options.characterSet, keeping: options.collation)
    }

    @ViewBuilder
    private var catalogStatusRow: some View {
        switch session.tableOptionsCatalog {
        case .idle, .loading:
            HStack {
                Text("Reading the server's character sets…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
        case .failed:
            HStack {
                Label("Couldn't read the server's character sets.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Try Again", action: onRetryCatalog)
                    .accessibilityIdentifier("structure-options-catalog-retry")
            }
        case .loaded:
            EmptyView()
        }
    }

    private func counterSection(maximum: UInt64, isEditable: Bool) -> some View {
        Section {
            TextField("Next Auto Increment", text: counterBinding)
                .focused($isCounterFocused)
                .disabled(!isEditable || !isCounterConfirmed)
                .accessibilityIdentifier("structure-options-auto-increment")
            // The server raises a value below the next free one, so a saved counter is read back, never shown as typed.
            switch session.autoIncrementRead {
            case .rereading:
                HStack {
                    Text("Reading the saved value…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            case .unconfirmed:
                HStack {
                    Label("Couldn't read the saved value.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again", action: onRetry)
                        .accessibilityIdentifier("structure-options-auto-increment-retry")
                }
            case .confirmed:
                EmptyView()
            }
            if let message = AutoIncrementEntry(
                counterText, maximum: maximum, original: changeManager.tableOptions.original?.autoIncrement
            ).message {
                Text(message)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("structure-options-auto-increment-error")
            }
        } footer: {
            Text("A value at or below the highest existing ID becomes that ID plus one.")
        }
    }

    // MARK: - Bindings

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
                guard var next = draft, let maximum = autoIncrementMaximum else { return }
                let entry = AutoIncrementEntry(
                    text, maximum: maximum, original: changeManager.tableOptions.original?.autoIncrement
                )
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

    private func syncCounterText() {
        counterText = displayedCounter.map { String($0) } ?? ""
    }
}
