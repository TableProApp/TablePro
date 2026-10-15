//
//  AIChatReasoningBlockView.swift
//  TablePro
//

import SwiftUI

/// Reasoning text arrives through the same 50 ms flush as the reply, which already coalesces it, so it is shown as it
/// comes. A debounce on top of the flush, longer than the flush, restarted on every one and never fired.
struct AIChatReasoningBlockView: View {
    let block: ReasoningBlock
    let isStreaming: Bool

    @State private var manualExpanded: Bool?

    private var isExpanded: Bool {
        manualExpanded ?? isStreaming
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { isExpanded },
            set: { manualExpanded = $0 }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            if let text = block.text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        } label: {
            Label(
                isStreaming ? String(localized: "Reasoning…") : String(localized: "Reasoning"),
                systemImage: isStreaming ? "ellipsis.bubble" : "lightbulb"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
