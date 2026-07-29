//
//  AIChatReasoningBlockView.swift
//  TablePro
//

import SwiftUI

struct AIChatReasoningBlockView: View {
    let block: ReasoningBlock
    let isStreaming: Bool

    @State private var displayedText: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var manualExpanded: Bool?

    private static let debounceInterval: Duration = .milliseconds(80)

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
            if !displayedText.isEmpty {
                Text(displayedText)
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
        .onAppear {
            displayedText = block.text ?? ""
        }
        .onChange(of: block.text ?? "") { _, newValue in
            scheduleUpdate(to: newValue)
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    private func scheduleUpdate(to newValue: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            displayedText = newValue
        }
    }
}
