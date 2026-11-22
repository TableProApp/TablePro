import SwiftUI

struct ClaudeAgentDisclosureSection: View {
    var body: some View {
        Section {
            ForEach(ClaudeAgentDisclosure.notes) { note in
                Label {
                    Text(verbatim: note.text)
                        .foregroundStyle(note.severity == .caution ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: note.severity.symbolName)
                        .foregroundStyle(note.severity == .caution ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
            }
            SettingsHelpRow(ClaudeAgentDisclosure.supportedAlternative)
        } header: {
            Text("Tradeoffs")
        }
    }
}
