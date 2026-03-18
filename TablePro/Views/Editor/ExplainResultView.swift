//
//  ExplainResultView.swift
//  TablePro
//
//  Displays EXPLAIN query results in a monospace text view.
//

import SwiftUI

struct ExplainResultView: View {
    let text: String
    let executionTime: TimeInterval?

    @State private var fontSize: CGFloat = 13
    @State private var showCopyConfirmation = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            DDLTextView(ddl: text, fontSize: $fontSize)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Button(action: { fontSize = max(10, fontSize - 1) }) {
                    Image(systemName: "textformat.size.smaller")
                }
                Text("\(Int(fontSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Button(action: { fontSize = min(24, fontSize + 1) }) {
                    Image(systemName: "textformat.size.larger")
                }
            }
            .buttonStyle(.borderless)

            if let time = executionTime {
                Text(formattedDuration(time))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showCopyConfirmation {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Copied!")
                }
                .transition(.opacity)
            }

            Button(action: copyText) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func copyText() {
        ClipboardService.shared.writeText(text)
        withAnimation { showCopyConfirmation = true }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            withAnimation { showCopyConfirmation = false }
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 0.001 {
            return "<1ms"
        } else if duration < 1.0 {
            return String(format: "%.0fms", duration * 1_000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }
}
