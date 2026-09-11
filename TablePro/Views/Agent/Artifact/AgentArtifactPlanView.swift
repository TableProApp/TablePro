//
//  AgentArtifactPlanView.swift
//  TablePro
//

import SwiftUI

/// The steps the session has taken, derived from its own tool calls.
///
/// Not a plan the model declared. A declared plan can drift from what happened and needs a prompt
/// contract to hold it together; a timeline read from the calls cannot say anything the session did
/// not do.
internal struct AgentArtifactPlanView: View {
    internal let steps: [AgentStep]

    internal var body: some View {
        List {
            ForEach(steps) { step in
                row(step)
            }
        }
        .listStyle(.inset)
    }

    /// The state is spoken, not only drawn. The icon is the whole of what tells a step apart from
    /// the one above it, and an unlabelled `Image` leaves VoiceOver reading the title with no idea
    /// whether it finished, failed or is waiting on the reader.
    private func row(_ step: AgentStep) -> some View {
        HStack(spacing: 0) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.callout)
                    if let detail = step.detail {
                        Text(detail)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            } icon: {
                Image(systemName: Self.icon(for: step.state))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Self.tint(for: step.state))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(format: String(localized: "%1$@, %2$@"), Self.stateName(step.state), step.title)
        )
    }

    private static func icon(for state: AgentStep.State) -> String {
        switch state {
        case .done: return "checkmark.circle"
        case .inFlight: return "circle.dotted"
        case .waitingOnYou: return "hand.raised"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private static func tint(for state: AgentStep.State) -> Color {
        switch state {
        case .done: return .secondary
        case .inFlight: return .accentColor
        case .waitingOnYou: return .orange
        case .failed: return .red
        }
    }

    private static func stateName(_ state: AgentStep.State) -> String {
        switch state {
        case .done: return String(localized: "Done")
        case .inFlight: return String(localized: "Working")
        case .waitingOnYou: return String(localized: "Waiting on you")
        case .failed: return String(localized: "Failed")
        }
    }
}
