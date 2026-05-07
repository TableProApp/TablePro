//
//  InlineAssistantPromptView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct InlineAssistantPromptView: View {
    var session: InlineAssistantSession
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onAccept: () -> Void
    var onReject: () -> Void

    @FocusState private var promptFieldFocused: Bool

    private static let maxPanelWidth: CGFloat = 560
    private static let maxDiffHeight: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            promptRow
            if session.hasResponse || session.isStreaming || session.phase == .idle {
                diffPanel
            }
            if case .failed(let message) = session.phase {
                errorRow(message: message)
            }
        }
        .padding(10)
        .frame(maxWidth: Self.maxPanelWidth)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 4)
        .onAppear {
            promptFieldFocused = true
        }
    }

    private var promptRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            TextField(
                String(localized: "Tell me how to change this..."),
                text: Binding(
                    get: { session.prompt },
                    set: { session.updatePrompt($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($promptFieldFocused)
            .disabled(session.isStreaming)
            .onSubmit {
                if session.canSubmit { onSubmit() }
            }

            if session.isStreaming {
                ProgressView()
                    .controlSize(.small)
            }

            actionButtons
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if session.hasResponse, case .ready = session.phase {
            Button(String(localized: "Reject"), action: onReject)
                .keyboardShortcut(.escape, modifiers: [])
                .controlSize(.small)
            Button(String(localized: "Accept"), action: onAccept)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.small)
        } else if session.isStreaming {
            Button(String(localized: "Stop"), action: onCancel)
                .controlSize(.small)
        } else {
            Button(String(localized: "Cancel"), action: onCancel)
                .keyboardShortcut(.escape, modifiers: [])
                .controlSize(.small)
            Button(String(localized: "Generate"), action: onSubmit)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!session.canSubmit)
        }
    }

    private var diffPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !session.originalText.isEmpty {
                    diffBlock(text: session.originalText, role: .removed)
                }
                if session.hasResponse {
                    diffBlock(text: session.proposedText, role: .added)
                } else if session.isStreaming {
                    diffBlock(text: String(localized: "Streaming..."), role: .placeholder)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: Self.maxDiffHeight)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private enum DiffRole {
        case removed, added, placeholder
    }

    @ViewBuilder
    private func diffBlock(text: String, role: DiffRole) -> some View {
        let attributed = makeDiffString(text: text, role: role)
        Text(attributed)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(diffBackground(for: role))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .textSelection(.enabled)
    }

    private func diffBackground(for role: DiffRole) -> Color {
        switch role {
        case .removed: return Color.red.opacity(0.10)
        case .added: return Color.green.opacity(0.12)
        case .placeholder: return Color.secondary.opacity(0.06)
        }
    }

    private func makeDiffString(text: String, role: DiffRole) -> AttributedString {
        var attr = AttributedString(text)
        switch role {
        case .removed:
            attr.foregroundColor = Color.red
            attr.strikethroughStyle = .single
        case .added:
            attr.foregroundColor = Color.green
        case .placeholder:
            attr.foregroundColor = Color.secondary
        }
        return attr
    }

    private func errorRow(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
            .padding(.horizontal, 4)
    }
}
