//
//  AIChatMessageView.swift
//  TablePro
//
//  Individual chat message view with native macOS inspector styling.
//

import AppKit
import MarkdownUI
import SwiftUI

/// Displays a single AI chat message with appropriate styling
struct AIChatMessageView: View {
    private static let userBubbleTintOpacity: Double = 0.08

    let message: ChatTurn
    var onRetry: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var onEdit: (() -> Void)?

    private var attachedContextItems: [ContextItem] {
        message.blocks.compactMap { block in
            if case .attachment(let item) = block { return item }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.role == .user {
                // User: timestamp header, then message text in tinted bubble
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

                    Markdown(message.plainText)
                        .markdownTheme(.tableProChat)
                        .textSelection(.enabled)
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
                // Assistant: role header above content
                roleHeader
                messageContent
            }

            // Footer (assistant only)
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

            // Retry button (error case)
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
        let renderable = renderableBlocks
        if renderable.isEmpty {
            TypingIndicatorView()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(renderable.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        Markdown(text)
                            .markdownTheme(.tableProChat)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                    case .toolUse(let useBlock):
                        AIChatToolUseBlockView(block: useBlock)
                    case .toolResult(let resultBlock):
                        AIChatToolResultBlockView(block: resultBlock)
                    case .attachment:
                        EmptyView()
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var renderableBlocks: [ChatContentBlock] {
        var result: [ChatContentBlock] = []
        for block in message.blocks {
            switch block {
            case .text(let text):
                if text.isEmpty { continue }
                if case .text(let existing) = result.last {
                    result[result.count - 1] = .text(existing + text)
                } else {
                    result.append(.text(text))
                }
            case .toolUse, .toolResult:
                result.append(block)
            case .attachment:
                continue
            }
        }
        return result
    }
}

// MARK: - TablePro Chat Theme

extension MarkdownUI.Theme {
    static let tableProChat = MarkdownUI.Theme()
        .text {
            FontSize(.em(1.0))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            ForegroundColor(Color(nsColor: .controlTextColor))
            BackgroundColor(Color(nsColor: .quaternarySystemFill))
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.5))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.3))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.15))
                }
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                        FontSize(.em(1.0))
                    }
                    .padding(Edge.Set.leading, 8)
            }
            .markdownMargin(top: 4, bottom: 4)
        }
        .codeBlock { configuration in
            AIChatCodeBlockView(
                code: configuration.content,
                language: configuration.language
            )
        }
}

// MARK: - Typing Indicator

/// Animated three-dot typing indicator
private struct TypingIndicatorView: View {
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onAppear { animating = true }
    }
}
