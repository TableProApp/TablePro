import SwiftUI

// A pull-down, not a pop-up: picking a preset is a one-time command, and the rows stay editable after it.
struct KeyboardPresetPullDown: View {
    let presets: [KeyboardPreset]
    let onChoose: (KeyboardPresetChoice) -> Void

    var body: some View {
        Menu(String(localized: "Use Shortcuts From")) {
            Button {
                onChoose(.tablePro)
            } label: {
                Text(verbatim: "TablePro")
            }
            if !presets.isEmpty {
                Divider()
            }
            ForEach(presets) { preset in
                Button {
                    onChoose(.preset(preset))
                } label: {
                    Text(verbatim: preset.name)
                }
            }
        }
        .fixedSize()
        .accessibilityIdentifier("shortcut-preset-menu")
    }
}
