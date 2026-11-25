import SwiftUI
import TableProTheme

// One theme slot's pop-up; Settings shows it as a Form row, the setup guide beside its own label.
internal struct ThemeSlotPicker: View {
    internal enum Placement {
        case formRow
        case labeled
    }

    private let slot: ThemeAppearance
    private let placement: Placement
    @Binding private var settings: AppearanceSettings

    @ObservedObject private var catalog = ThemeCatalog.shared

    internal init(slot: ThemeAppearance, settings: Binding<AppearanceSettings>, placement: Placement = .formRow) {
        self.slot = slot
        self.placement = placement
        _settings = settings
    }

    private var choice: ThemeSlotChoice {
        let savedId = switch slot {
        case .light: settings.preferredLightThemeId
        case .dark: settings.preferredDarkThemeId
        }
        return ThemeSlotChoice(slot: slot, savedId: savedId, themes: catalog.themes)
    }

    internal var body: some View {
        let choice = choice
        switch placement {
        case .formRow:
            picker(choice) {
                Text(choice.title)
                if let note = choice.noteMessage {
                    Text(note)
                        .accessibilityIdentifier(noteIdentifier)
                }
            }
        case .labeled:
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent {
                    picker(choice) { Text(choice.title) }
                        .labelsHidden()
                        .fixedSize()
                } label: {
                    Text(choice.title)
                        .accessibilityHidden(true)
                }
                if let note = choice.noteMessage {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(noteIdentifier)
                }
            }
        }
    }

    private var noteIdentifier: String {
        "appearance-\(slot.rawValue)-theme-note"
    }

    private func picker<Label: View>(_ choice: ThemeSlotChoice, @ViewBuilder label: () -> Label) -> some View {
        Picker(selection: selectionBinding(for: choice)) {
            ForEach(choice.builtIn) { theme in
                Text(theme.name).tag(theme.id)
            }
            if !choice.custom.isEmpty {
                Divider()
                ForEach(choice.custom) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
        } label: {
            label()
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("appearance-\(slot.rawValue)-theme")
    }

    // Shows the theme in use, but only a pick writes, so a saved id this Mac cannot resolve stays for the Mac that has it.
    private func selectionBinding(for choice: ThemeSlotChoice) -> Binding<String> {
        Binding(
            get: { choice.selectedId },
            set: { id in
                var updated = settings
                switch choice.slot {
                case .light: updated.preferredLightThemeId = id
                case .dark: updated.preferredDarkThemeId = id
                }
                settings = updated
            }
        )
    }
}
