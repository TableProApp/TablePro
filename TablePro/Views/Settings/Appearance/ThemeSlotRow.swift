import AppKit
import SwiftUI
import TableProTheme

/// One color of the theme: its name, where the color comes from, the system color well, and a reset
/// that appears only while the file sets the slot.
internal struct ThemeSlotRow: View {
    internal let presentation: ThemeSlotPresentation
    internal let isEditable: Bool
    internal let onSet: (ThemeColor) -> Void
    internal let onReset: () -> Void

    private var slot: ThemeSlot { presentation.slot }

    internal var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if presentation.hasExplicitColor, isEditable {
                    Button(action: onReset) {
                        Label(presentation.resetTitle, systemImage: "arrow.uturn.backward")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(presentation.resetTitle)
                    .accessibilityLabel(presentation.resetAccessibilityLabel)
                    .accessibilityIdentifier("theme-color-reset-\(slot.rawValue)")
                }

                ThemeColorWell(
                    color: presentation.displayColor,
                    canPickOpacity: slot.offersOpacity,
                    isEnabled: isEditable,
                    label: slot.accessibilityLabel,
                    identifier: "theme-color-\(slot.rawValue)",
                    onPick: onSet
                )
                .fixedSize()
            }
        } label: {
            Text(slot.label)
            Text(presentation.stateLine)
                .accessibilityIdentifier("theme-color-state-\(slot.rawValue)")
        }
        .contextMenu {
            if presentation.hasExplicitColor, isEditable {
                Button(presentation.resetTitle, action: onReset)
            }
        }
    }
}

/// AppKit on purpose: `ColorPicker` reports every color the shared panel sends, and activating a
/// well without opacity turns the panel's alpha off, which sends the previous well's color and then
/// this one's, both made opaque. Taken as picks, they froze a system color into the file.
private struct ThemeColorWell: NSViewRepresentable {
    let color: ThemeColor
    let canPickOpacity: Bool
    let isEnabled: Bool
    let label: String
    let identifier: String
    let onPick: (ThemeColor) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ThemeSlotColorWell {
        let well = ThemeSlotColorWell(frame: .zero)
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorPicked(_:))
        return well
    }

    func updateNSView(_ well: ThemeSlotColorWell, context: Context) {
        context.coordinator.onPick = onPick
        well.canPickOpacity = canPickOpacity
        well.isEnabled = isEnabled && context.environment.isEnabled
        well.setAccessibilityLabel(label)
        well.setAccessibilityIdentifier(identifier)
        // A well without opacity holds an opaque copy, so comparing with its own color would rewrite it
        // on every update.
        guard context.coordinator.shownColor != color else { return }
        context.coordinator.shownColor = color
        well.show(color.nsColor)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPick: (ThemeColor) -> Void = { _ in }
        var shownColor: ThemeColor?

        @objc func colorPicked(_ sender: NSColorWell) {
            let picked = ThemeColor(sender.color)
            shownColor = picked
            onPick(picked)
        }
    }
}

/// A well that sends its action only for a color the user picks: the panel's sends while the well
/// activates, or while code sets its color, are the panel catching up.
internal final class ThemeSlotColorWell: NSColorWell {
    private var isSettingItself = false

    internal var canPickOpacity = true {
        didSet {
            guard canPickOpacity != oldValue else { return }
            if #available(macOS 14, *) {
                supportsAlpha = canPickOpacity
            }
        }
    }

    internal func show(_ shown: NSColor) {
        isSettingItself = true
        defer { isSettingItself = false }
        color = shown
    }

    override func activate(_ exclusive: Bool) {
        isSettingItself = true
        defer { isSettingItself = false }
        if #unavailable(macOS 14) {
            NSColorPanel.shared.showsAlpha = canPickOpacity
        }
        super.activate(exclusive)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard !isSettingItself else { return false }
        return super.sendAction(action, to: target)
    }
}
