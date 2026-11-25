import AppKit
import SwiftUI

// A List, not a grouped Form: a Form builds all 126 rows on first show, a List only the visible ones.
struct KeyboardSettingsView: View {
    @ObservedObject private var keyboard: SettingsSlice<KeyboardSettings>
    @ObservedObject private var filter: SettingsPaneFilter
    @ObservedObject private var modules = AppModuleSettings.shared
    @StateObject private var session: ShortcutRecordingSession
    @State private var selection: ShortcutAction?
    @State private var confirmsRestore = false

    init(keyboard: SettingsSlice<KeyboardSettings>, filter: SettingsPaneFilter) {
        _keyboard = ObservedObject(wrappedValue: keyboard)
        _filter = ObservedObject(wrappedValue: filter)
        _session = StateObject(wrappedValue: ShortcutRecordingSession(keyboard: keyboard))
    }

    var body: some View {
        let settings = keyboard.value
        let sections = ShortcutAction.settingsSections(
            matching: filter.query,
            in: settings,
            enabledModules: modules.enabledModules
        )
        SettingsFullPageList {
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section(section.category.displayName) {
                        ForEach(section.actions, id: \.self) { action in
                            row(for: action, in: settings)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: ShortcutAction.self) { actions in
                if let action = actions.first {
                    rowMenu(for: action, in: settings)
                }
            } primaryAction: { actions in
                if let action = actions.first {
                    session.begin(action)
                }
            }
        } emptyState: {
            if sections.isEmpty {
                UnavailableStateView.search(text: filter.query)
            }
        } bar: {
            SettingsListBar {
                Text(Self.summary(customized: settings.customizedCount, preset: appliedPresetName(settings)))
                    .foregroundStyle(.secondary)
            } trailing: {
                HStack(spacing: 8) {
                    KeyboardPresetPullDown(presets: Self.catalog?.listing(first: nil) ?? []) { choice in
                        Task {
                            _ = await KeyboardPresetActions.choose(choice, in: keyboard, window: nil)
                        }
                    }
                    Button(String(localized: "Restore Defaults…")) {
                        confirmsRestore = true
                    }
                    .disabled(settings.shortcuts.isEmpty)
                    .accessibilityIdentifier("shortcut-restore-defaults")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-pane-keyboard")
        .alert(
            session.reassignment?.title ?? "",
            isPresented: Binding(
                get: { session.reassignment != nil },
                set: { if !$0 { session.dismissReassignment() } }
            ),
            presenting: session.reassignment
        ) { request in
            Button(String(localized: "Reassign")) {
                session.confirm(request)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .alert(String(localized: "Restore Default Shortcuts?"), isPresented: $confirmsRestore) {
            Button(String(localized: "Restore Defaults"), role: .destructive) {
                keyboard.value = .default
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Every shortcut you changed goes back to its default."))
        }
        .onDisappear {
            session.reset()
        }
    }

    private func row(for action: ShortcutAction, in settings: KeyboardSettings) -> some View {
        let isArmed = session.recording == action
        return ShortcutRow(
            action: action,
            key: settings.boundKey(for: action),
            isCustomized: settings.isCustomized(action),
            claimant: settings.defaultClaimant(for: action),
            refusal: session.feedback?.action == action ? session.feedback?.message : nil,
            isArmed: isArmed,
            heldModifiers: isArmed ? session.heldModifiers : [],
            keyboard: keyboard,
            session: session
        )
    }

    @ViewBuilder
    private func rowMenu(for action: ShortcutAction, in settings: KeyboardSettings) -> some View {
        Button(String(localized: "Record Shortcut")) {
            session.begin(action)
        }
        Button(String(localized: "Remove Shortcut")) {
            keyboard.value = keyboard.value.clearing(action)
        }
        .disabled(settings.boundKey(for: action) == nil)
        Button(String(localized: "Reset to Default")) {
            keyboard.value = keyboard.value.resetting(action)
        }
        .disabled(!settings.isCustomized(action))
    }

    static func summary(customized count: Int) -> String {
        count == 0
            ? String(localized: "No custom shortcuts")
            : String(format: String(localized: "%lld customized"), count)
    }

    static func summary(customized count: Int, preset name: String?) -> String {
        guard let name else { return summary(customized: count) }
        return String(format: String(localized: "%@ shortcuts"), name)
    }

    private static let catalog = KeyboardPresetCatalog.bundled()

    private func appliedPresetName(_ settings: KeyboardSettings) -> String? {
        guard let catalog = Self.catalog, let id = settings.appliedPreset(in: catalog) else { return nil }
        return catalog.presets.first { $0.id == id }?.name
    }
}

// Plain values only, so arming or a refusal re-renders just the rows it touches.
private struct ShortcutRow: View {
    let action: ShortcutAction
    let key: BoundKey?
    let isCustomized: Bool
    let claimant: ShortcutAction?
    let refusal: String?
    let isArmed: Bool
    let heldModifiers: NSEvent.ModifierFlags
    let keyboard: SettingsSlice<KeyboardSettings>
    let session: ShortcutRecordingSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.displayName)
                note
            }
            Spacer(minLength: 12)
            if isCustomized {
                resetButton
            }
            ShortcutRecorderField(
                action: action,
                key: key,
                isArmed: isArmed,
                heldModifiers: heldModifiers,
                session: session
            )
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            Button(String(localized: "Record Shortcut")) {
                session.begin(action)
            }
            if key != nil {
                Button(String(localized: "Remove Shortcut")) {
                    keyboard.value = keyboard.value.clearing(action)
                }
            }
            if isCustomized {
                Button(String(localized: "Reset to Default")) {
                    keyboard.value = keyboard.value.resetting(action)
                }
            }
        }
    }

    @ViewBuilder private var note: some View {
        if let refusal {
            // One Text, not a NoticeLabel: a Label moves the row separator to its title, past the glyph.
            (Text(Image(systemName: NoticeSeverity.warning.symbolName)).foregroundColor(NoticeSeverity.warning.tint)
                + Text(verbatim: " " + refusal))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else if let claimant, let fallback = KeyboardSettings.defaultShortcuts[action] {
            Text(String(
                format: String(localized: "Default %@ is used by “%@”."),
                fallback.displayString,
                claimant.displayName
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var resetButton: some View {
        Button {
            keyboard.value = keyboard.value.resetting(action)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .frame(minWidth: 20, minHeight: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(resetHelp)
        .accessibilityLabel(String(format: String(localized: "Reset %@ to default"), action.displayName))
        .accessibilityIdentifier("shortcut-reset-\(action.rawValue)")
    }

    private var resetHelp: String {
        guard let fallback = KeyboardSettings.defaultShortcuts[action] else {
            return String(localized: "Reset to None")
        }
        return String(format: String(localized: "Reset to %@"), fallback.displayString)
    }
}
