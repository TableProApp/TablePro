//
//  ClaudeAgentDisclosureSection.swift
//  TablePro
//

import SwiftUI

struct ClaudeAgentDisclosureSection: View {
    var body: some View {
        Section {
            ForEach(ClaudeAgentDisclosure.notes) { note in
                Label {
                    Text(note.text)
                        .font(.callout)
                        .foregroundStyle(note.severity == .caution ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: note.severity.symbolName)
                        .foregroundStyle(note.severity == .caution ? Color.orange : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Tradeoffs")
        } footer: {
            Text(ClaudeAgentDisclosure.supportedAlternative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
