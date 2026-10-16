import SwiftUI
import TableProTheme

/// The Theme Editor window's content: a live preview over the theme's fields. The window is chrome,
/// so only the preview wears the theme.
internal struct ThemeEditorView: View {
    @ObservedObject internal var model: ThemeEditorModel
    internal let onDuplicate: () -> Void

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case author
    }

    internal var body: some View {
        VStack(spacing: 0) {
            ThemeEditorPreview(scope: model.previewScope, appearance: model.draft.appearance)

            Divider()

            Form {
                if model.isReadOnly {
                    builtInSection
                }
                generalSection
                ForEach(ThemeSlotSection.allCases, id: \.self) { section in
                    slotSection(section)
                }
            }
            .formStyle(.grouped)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("theme-editor-slots")

            if !model.isReadOnly {
                Divider()
                footer
            }
        }
        .onChange(of: focusedField) { field in
            if field != .name { model.commitName() }
            if field != .author { model.commitAuthor() }
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0 { model.alert = nil } }
            ),
            presenting: model.alert
        ) { alert in
            alertButtons(for: alert)
        } message: { alert in
            Text(alert.message)
        }
    }

    // MARK: - Sections

    private var builtInSection: some View {
        Section {
            HStack {
                Text("Built-in themes can't be changed.")
                Spacer()
                Button(String(localized: "Duplicate"), action: onDuplicate)
                    .accessibilityIdentifier("theme-editor-duplicate")
            }
        }
    }

    private var generalSection: some View {
        Section(String(localized: "General")) {
            TextField(String(localized: "Name"), text: $model.nameText)
                .focused($focusedField, equals: .name)
                .onSubmit { model.commitName() }
                .accessibilityIdentifier("theme-editor-name")
            if let error = model.nameError {
                fieldError(error, identifier: "theme-editor-name-error")
            }

            Picker(String(localized: "Appearance"), selection: appearanceBinding) {
                Text(ThemeLibraryModel.appearanceLabel(.light)).tag(ThemeAppearance.light)
                Text(ThemeLibraryModel.appearanceLabel(.dark)).tag(ThemeAppearance.dark)
            }
            .accessibilityIdentifier("theme-editor-appearance")

            TextField(String(localized: "Author"), text: $model.authorText)
                .focused($focusedField, equals: .author)
                .onSubmit { model.commitAuthor() }
                .accessibilityIdentifier("theme-editor-author")
            if let error = model.authorError {
                fieldError(error, identifier: "theme-editor-author-error")
            }
        }
        .disabled(!model.isEditable)
    }

    private func slotSection(_ section: ThemeSlotSection) -> some View {
        Section {
            ForEach(section.slots, id: \.self) { slot in
                ThemeSlotRow(
                    presentation: ThemeSlotPresentation(slot: slot, theme: model.draft),
                    isEditable: model.isEditable,
                    onSet: { model.setColor($0, for: slot) },
                    onReset: { model.reset(slot) }
                )
            }
        } header: {
            Text(section.label)
        } footer: {
            sectionFooter(section)
        }
    }

    @ViewBuilder
    private func sectionFooter(_ section: ThemeSlotSection) -> some View {
        if section == .window {
            Text("With Increase Contrast on, the window uses the system background.")
        } else if let note = ThemeContrastNote.message(for: section, in: model.draft) {
            Text(note)
                .accessibilityIdentifier("theme-editor-contrast-\(section.rawValue)")
        }
    }

    private func fieldError(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Revert Changes")) { model.revert() }
                .disabled(!model.isEditable || !model.hasChangesSinceOpening)
                .accessibilityIdentifier("theme-editor-revert")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var appearanceBinding: Binding<ThemeAppearance> {
        Binding(
            get: { model.draft.appearance },
            set: { model.setAppearance($0) }
        )
    }

    // MARK: - Alerts

    @ViewBuilder
    private func alertButtons(for alert: ThemeEditorModel.Alert) -> some View {
        switch alert {
        case .changedOnDisk, .saveFailed:
            Button(String(localized: "OK")) {}
        case .unreadableOnDisk:
            Button(String(localized: "Close")) { model.requestClose() }
        case .deletedOnDisk:
            Button(String(localized: "Keep Theme")) { model.keepAsNewTheme() }
            Button(String(localized: "Close"), role: .cancel) { model.requestClose() }
        }
    }
}

internal extension ThemeEditorModel.Alert {
    var title: String {
        switch self {
        case let .changedOnDisk(name), let .unreadableOnDisk(name):
            return String(format: String(localized: "“%@” Changed on Disk"), name)
        case let .deletedOnDisk(name):
            return String(format: String(localized: "“%@” Was Deleted"), name)
        case let .saveFailed(name, _):
            return String(format: String(localized: "Couldn't Save “%@”"), name)
        }
    }

    var message: String {
        switch self {
        case .changedOnDisk:
            return String(localized: "It was changed outside TablePro. The editor now shows the newer version.")
        case .unreadableOnDisk:
            return String(localized: "It was changed outside TablePro and no longer loads. Settings > Appearance lists it under Not Loaded with the reason.")
        case .deletedOnDisk:
            return String(localized: "The file was removed outside TablePro, possibly on another Mac.")
        case let .saveFailed(_, reason):
            return reason
        }
    }
}
