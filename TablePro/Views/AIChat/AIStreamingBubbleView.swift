//
//  AIStreamingBubbleView.swift
//  TablePro
//

import SwiftUI

struct AIStreamingBubbleView: View {
    @Bindable var viewModel: AIChatViewModel
    let timestamp: Date

    var body: some View {
        _ = viewModel.streamingTick
        let text = viewModel.streamingText
        let hasText = !text.isEmpty

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                Text("·")
                Text(timestamp, style: .time)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            if hasText {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ChatTypingIndicatorView()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

