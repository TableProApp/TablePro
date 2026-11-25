import AppKit
import SwiftUI
import TableProTheme

// The pop-up shows what the shortcuts are now, so Keep Current puts back the ones the guide found.
internal struct SetupGuideShortcuts: Equatable {
    internal enum Option: Hashable {
        case keepCurrent
        case tablePro
        case preset(KeyboardPreset.ID)
    }

    internal let original: KeyboardSettings
    internal var presets: [KeyboardPreset]
    internal private(set) var selection: Option

    internal init(original: KeyboardSettings, presets: [KeyboardPreset]) {
        self.original = original
        self.presets = presets
        selection = original.isCustomized ? .keepCurrent : .tablePro
    }

    internal var options: [Option] {
        (original.isCustomized ? [.keepCurrent] : []) + [.tablePro] + presets.map { .preset($0.id) }
    }

    internal func title(of option: Option) -> String {
        switch option {
        case .keepCurrent: String(localized: "Keep Current")
        case .tablePro: "TablePro"
        case .preset(let id): presets.first(where: { $0.id == id })?.name ?? id
        }
    }

    // Asked only when shortcuts changed by hand are about to go.
    internal func asksBeforeSelecting(_ option: Option) -> Bool {
        original.isCustomized && selection == .keepCurrent && option != .keepCurrent
    }

    internal func settings(for option: Option, isSystemHotkey: (BoundKey) -> Bool) -> KeyboardSettings {
        switch option {
        case .keepCurrent:
            return original
        case .tablePro:
            return .default
        case .preset(let id):
            guard let preset = presets.first(where: { $0.id == id }) else { return .default }
            return KeyboardSettings.default.applying(preset, isSystemHotkey: isSystemHotkey)
        }
    }

    internal mutating func select(_ option: Option) {
        selection = option
    }
}

internal struct SetupGuideOptionsStep: View {
    @ObservedObject var model: SetupGuideModel
    @ObservedObject private var appearance: SettingsSlice<AppearanceSettings>
    @ObservedObject private var appearanceMode: SettingsSlice<AppAppearanceMode>
    @ObservedObject private var editor: SettingsSlice<EditorSettings>
    @ObservedObject private var keyboard: SettingsSlice<KeyboardSettings>

    internal init(model: SetupGuideModel, settings: AppSettingsManager = .shared) {
        self.model = model
        _appearance = ObservedObject(wrappedValue: settings.appearanceSlice)
        _appearanceMode = ObservedObject(wrappedValue: settings.appearanceModeSlice)
        _editor = ObservedObject(wrappedValue: settings.editorSlice)
        _keyboard = ObservedObject(wrappedValue: settings.keyboardSlice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section(String(localized: "Appearance")) {
                SetupGuideAppearanceTiles(mode: $appearanceMode.value)
                Text(verbatim: String(localized: "Controls, sidebars and Settings follow this. Applies to this Mac."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            section(String(localized: "Themes")) {
                SetupGuideSettingsCard {
                    ThemeSlotPicker(slot: .light, settings: $appearance.value, placement: .labeled)
                    ThemeSlotPicker(slot: .dark, settings: $appearance.value, placement: .labeled)
                }
                .labeledContentStyle(SettingsRowStyle())
            }
            section(String(localized: "Keyboard")) {
                SetupGuideSettingsCard {
                    LabeledContent {
                        Picker(String(localized: "Key bindings"), selection: $editor.value.keyBindings) {
                            Text(verbatim: String(localized: "Standard")).tag(EditorKeyBindings.standard)
                            Text(verbatim: "Vim").tag(EditorKeyBindings.vim)
                            Text(verbatim: "Emacs").tag(EditorKeyBindings.emacs)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("setup-guide-key-bindings")
                    } label: {
                        rowLabel(String(localized: "Key bindings"))
                    }
                    if let shortcuts = model.shortcuts {
                        LabeledContent {
                            Picker(String(localized: "Shortcuts"), selection: shortcutBinding(shortcuts)) {
                                ForEach(shortcuts.options, id: \.self) { option in
                                    Text(verbatim: shortcuts.title(of: option)).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("setup-guide-shortcut-preset")
                        } label: {
                            rowLabel(String(localized: "Shortcuts"))
                        }
                    }
                    Text(verbatim: String(localized: "Menu and editor keys. Pick the app you used before to keep its keys."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .labeledContentStyle(SettingsRowStyle())
            }
        }
    }

    // The pop-up carries the same name, so VoiceOver reads it once.
    private func rowLabel(_ title: String) -> some View {
        Text(verbatim: title)
            .accessibilityHidden(true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func shortcutBinding(_ shortcuts: SetupGuideShortcuts) -> Binding<SetupGuideShortcuts.Option> {
        Binding(
            get: { shortcuts.selection },
            set: { option in
                guard option != shortcuts.selection else { return }
                Task { @MainActor in await choose(option, in: shortcuts) }
            }
        )
    }

    private func choose(_ option: SetupGuideShortcuts.Option, in shortcuts: SetupGuideShortcuts) async {
        if shortcuts.asksBeforeSelecting(option) {
            let confirmed = await KeyboardPresetConfirmation.confirmReplacing(
                customizedCount: shortcuts.original.customizedCount,
                with: shortcuts.title(of: option),
                window: NSApp.keyWindow
            )
            guard confirmed else { return }
        }
        keyboard.value = shortcuts.settings(for: option, isSystemHotkey: { SystemHotkeyChecker.shared.isReserved($0) })
        model.selectShortcut(option)
    }
}

private struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}
