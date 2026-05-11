//
//  AIChatMessageView.swift
//  TablePro
//
//  Individual chat message view with native macOS inspector styling.
//

import AppKit
import SwiftUI

struct AIChatMessageView: View {
    private static let userBubbleTintOpacity: Double = 0.08

    let message: ChatTurn
    var onRetry: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onEdit: (() -> Void)?

    private var attachedContextItems: [ContextItem] {
        message.blocks.compactMap { block in
            if case .attachment(let item) = block.kind { return item }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.role == .user {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("You")
                            .fontWeight(.medium)
                        Text("·")
                        Text(message.timestamp, style: .time)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if !attachedContextItems.isEmpty {
                        AIChatContextChipStrip(items: attachedContextItems)
                            .padding(.bottom, 2)
                    }

                    MarkdownView(source: message.plainText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let onEdit {
                        HStack {
                            Spacer()
                            Button { onEdit() } label: {
                                Image(systemName: "pencil")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help(String(localized: "Edit message"))
                            .accessibilityLabel(String(localized: "Edit message"))
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(Self.userBubbleTintOpacity))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                roleHeader
                messageContent
            }

            if message.role == .assistant {
                HStack(spacing: 8) {
                    if let onRegenerate {
                        Button { onRegenerate() } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    if let modelId = message.modelId, !modelId.isEmpty {
                        Text(modelId)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let usage = message.usage {
                        Text("\(usage.inputTokens) in · \(usage.outputTokens) out")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 8)
            }

            if let onRetry {
                Button {
                    onRetry()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(Color(nsColor: .systemRed))
                        Text("Generation failed.")
                            .foregroundStyle(.secondary)
                        Text("Retry")
                            .fontWeight(.medium)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
        }
    }

    private var roleHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.caption2)
            Text("·")
            Text(message.timestamp, style: .time)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var messageContent: some View {
        let visibleBlocks = message.blocks.filter { block in
            switch block.kind {
            case .text(let text):
                return !text.isEmpty || block.isStreaming
            case .toolUse, .toolResult:
                return true
            case .attachment:
                return false
            }
        }
        if visibleBlocks.isEmpty {
            ChatTypingIndicatorView()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleBlocks) { block in
                    AIChatBlockView(block: block)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct AIChatBlockView: View {
    @Bindable var block: ChatContentBlock

    var body: some View {
        switch block.kind {
        case .text(let text):
            if block.isStreaming {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            } else {
                MarkdownView(source: text)
                    .padding(.horizontal, 8)
            }
        case .toolUse(let useBlock):
            AIChatToolUseBlockView(block: useBlock)
        case .toolResult(let resultBlock):
            AIChatToolResultBlockView(block: resultBlock)
        case .attachment:
            EmptyView()
        }
    }
}

struct ChatTypingIndicatorView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
    }
}
