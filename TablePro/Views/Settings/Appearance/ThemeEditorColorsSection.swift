import AppKit
import os
import SwiftUI

/// One well per registered slot, driven by `ThemeSlot.allCases`, so a slot the app gains appears
/// here without a second hand-maintained list to keep in step.
internal struct ThemeEditorColorsSection: View {
    internal let theme: ThemeDefinition

    @State private var draft: ThemeDefinition?
    @State private var saveTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEditorColors")
    private static let saveDelay = Duration.milliseconds(250)

    private var edited: ThemeDefinition {
        guard let draft, draft.id == theme.id else { return theme }
        return draft
    }

    internal var body: some View {
        Form {
            ForEach(ThemeSlotGroup.allCases, id: \.self) { group in
                Section(group.label) {
                    ForEach(group.slots, id: \.self) { slot in
                        row(for: slot)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { flush() }
    }

    private func row(for slot: ThemeSlot) -> some View {
        let value = edited[keyPath: slot.keyPath]

        return LabeledContent(slot.label) {
            HStack(spacing: 8) {
                if case let .system(name) = value {
                    Text(name.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ColorPicker("", selection: binding(for: slot), supportsOpacity: true)
                    .labelsHidden()
                    .accessibilityLabel(Text(slot.label))
            }
            .contextMenu {
                if case .hex = value, case let .system(name) = BuiltInThemes.default(for: theme.appearance)[keyPath: slot.keyPath] {
                    Button(String(format: String(localized: "Use System Color (%@)"), name.rawValue)) {
                        write(.system(name), to: slot)
                    }
                }
            }
        }
    }

    private var editedAppearance: NSAppearance? {
        NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
    }

    private func resolved(_ value: ThemeColorValue) -> NSColor {
        guard value.isSystem, let editedAppearance else { return value.nsColor }

        var color = value.nsColor
        editedAppearance.performAsCurrentDrawingAppearance {
            color = value.nsColor.usingColorSpace(.sRGB) ?? value.nsColor
        }
        return color
    }

    private func binding(for slot: ThemeSlot) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: resolved(edited[keyPath: slot.keyPath])) },
            set: { newColor in
                write(.hex(HexColor.string(from: NSColor(newColor))), to: slot)
            }
        )
    }

    /// The well emits on every drag tick, and each one used to write the file, rescan the themes
    /// directory and re-activate. The draft absorbs the ticks and one save follows the settle.
    private func write(_ value: ThemeColorValue, to slot: ThemeSlot) {
        var updated = edited
        updated[keyPath: slot.keyPath] = value
        draft = updated

        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            save(updated)
        }
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let draft, draft != theme else { return }
        save(draft)
    }

    private func save(_ updated: ThemeDefinition) {
        do {
            try ThemeCatalog.shared.save(updated)
            let appearance = AppSettingsManager.shared.appearance
            ThemeEngine.shared.reapply(
                lightThemeId: appearance.preferredLightThemeId,
                darkThemeId: appearance.preferredDarkThemeId
            )
        } catch {
            Self.logger.error("Could not save theme: \(error.localizedDescription)")
        }
    }
}
