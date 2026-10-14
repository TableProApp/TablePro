import os
import SwiftUI

/// Edits one custom theme in place. Every change is saved shortly after it settles, so Done only
/// closes the sheet; there is no draft to throw away.
internal struct ThemeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ThemeEditorDraft
    @State private var lastSaved: ThemeDefinition
    @State private var name: String
    @State private var saveTask: Task<Void, Never>?
    @State private var saveError: String?

    private let takenNames: Set<String>
    private let save: @MainActor (ThemeDefinition) throws -> Void

    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEditorSheet")
    // A color well reports every drag tick; one write follows the settle.
    private static let saveDelay = Duration.milliseconds(250)

    internal init(
        theme: ThemeDefinition,
        takenNames: Set<String>,
        save: @escaping @MainActor (ThemeDefinition) throws -> Void
    ) {
        _draft = State(initialValue: ThemeEditorDraft(theme: theme))
        _lastSaved = State(initialValue: theme)
        _name = State(initialValue: theme.name)
        self.takenNames = takenNames
        self.save = save
    }

    internal var body: some View {
        VStack(spacing: 0) {
            ThemePreviewCard(theme: draft.theme)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            Form {
                Section {
                    TextField(String(localized: "Name"), text: $name)
                        .onSubmit(commitName)
                        .accessibilityIdentifier("theme-editor-name")
                }

                ForEach(ThemeSlotGroup.allCases, id: \.self) { group in
                    Section(group.label) {
                        ForEach(group.slots, id: \.self) { slot in
                            colorRow(slot)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Done"), action: finish)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("theme-editor-done")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 460, idealHeight: 600)
        .onExitCommand(perform: finish)
        .onDisappear { flush() }
        .alert(
            String(localized: "Could not save the theme"),
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func colorRow(_ slot: ThemeSlot) -> some View {
        LabeledContent(slot.label) {
            HStack(spacing: 6) {
                if draft.theme.isOverridden(slot) {
                    Button {
                        if draft.reset(slot) { scheduleSave() }
                    } label: {
                        Label(String(localized: "Use Default"), systemImage: "arrow.uturn.backward")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Use Default"))
                    .accessibilityLabel(String(localized: "Use Default"))
                    .accessibilityIdentifier("theme-color-reset-\(slot.rawValue)")
                }

                ColorPicker(slot.label, selection: colorBinding(for: slot), supportsOpacity: true)
                    .labelsHidden()
                    .accessibilityIdentifier("theme-color-\(slot.rawValue)")
            }
        }
    }

    private func colorBinding(for slot: ThemeSlot) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: draft.displayColor(for: slot)) },
            set: { newColor in
                if draft.setColor(ThemeColor(NSColor(newColor)), for: slot) {
                    scheduleSave()
                }
            }
        )
    }

    private func commitName() {
        guard let renamed = ThemeNaming.renamed(name, current: draft.theme.name, takenNames: takenNames) else {
            name = draft.theme.name
            return
        }
        name = renamed
        if draft.rename(to: renamed) {
            scheduleSave()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = Self.saveDelay
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            write(draft.theme)
        }
    }

    @discardableResult
    private func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard draft.theme != lastSaved else { return true }
        return write(draft.theme)
    }

    @discardableResult
    private func write(_ theme: ThemeDefinition) -> Bool {
        do {
            try save(theme)
            lastSaved = theme
            return true
        } catch {
            Self.logger.error("Could not save theme: \(error.publicLogShape, privacy: .public)")
            saveError = error.localizedDescription
            adoptDiskVersionAfterConflict(error, id: theme.id)
            return false
        }
    }

    /// After a conflict the catalog holds the file's newer contents; editing on from the stale draft
    /// would overwrite them with the next save.
    private func adoptDiskVersionAfterConflict(_ error: Error, id: String) {
        guard case .changedOnDisk = error as? ThemeLoadError,
              let current = ThemeCatalog.shared.theme(id: id) else { return }
        draft = ThemeEditorDraft(theme: current)
        lastSaved = current
        name = current.name
    }

    private func finish() {
        commitName()
        guard flush() else { return }
        dismiss()
    }
}
