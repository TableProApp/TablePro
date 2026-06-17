//
//  ExplainResultView.swift
//  TablePro
//
//  Displays EXPLAIN query results with toggle between diagram, tree, and raw text.
//

import SwiftUI

private enum ExplainViewMode: String, CaseIterable {
    case diagram = "Diagram"
    case tree = "Tree"
    case raw = "Raw"
}

struct ExplainResultView: View {
    let text: String
    let executionTime: TimeInterval?
    let plan: QueryPlan?

    @State private var fontSize: Double = 13
    @State private var showCopyConfirmation = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var viewMode: ExplainViewMode = .diagram

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch viewMode {
            case .diagram:
                if let plan {
                    QueryPlanDiagramView(plan: plan)
                } else {
                    DDLTextView(ddl: text, fontSize: $fontSize)
                }
            case .tree:
                if let plan {
                    QueryPlanTreeView(plan: plan)
                } else {
                    DDLTextView(ddl: text, fontSize: $fontSize)
                }
            case .raw:
                DDLTextView(ddl: text, fontSize: $fontSize)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if plan != nil {
                Picker("", selection: $viewMode) {
                    Text(String(localized: "Diagram")).tag(ExplainViewMode.diagram)
                    Text(String(localized: "Tree")).tag(ExplainViewMode.tree)
                    Text(String(localized: "Raw")).tag(ExplainViewMode.raw)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 240)
                .labelsHidden()
            }

            if viewMode == .raw || plan == nil {
                HStack(spacing: 4) {
                    Button(action: { fontSize = max(10, fontSize - 1) }) {
                        Image(systemName: "textformat.size.smaller")
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel(String(localized: "Decrease font size"))
                    Text("\(Int(fontSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Button(action: { fontSize = min(24, fontSize + 1) }) {
                        Image(systemName: "textformat.size.larger")
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel(String(localized: "Increase font size"))
                }
                .buttonStyle(.borderless)
            }

            if let plan {
                if let planTime = plan.planningTime {
                    Text(String(format: String(localized: "Planning: %.3fms"), planTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let execTime = plan.executionTime {
                    Text(String(format: String(localized: "Execution: %.3fms"), execTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let time = executionTime {
                Text(formattedDuration(time))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if showCopyConfirmation {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(String(localized: "Copied!"))
                }
                .transition(.opacity)
            }

            Button(action: copyText) {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(String(localized: "Copy EXPLAIN output to clipboard"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
