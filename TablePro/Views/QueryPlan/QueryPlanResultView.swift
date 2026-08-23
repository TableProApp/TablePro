//
//  QueryPlanResultView.swift
//  TablePro
//
//  One EXPLAIN result, as a diagram, an outline, or the raw text the database returned.
//

import SwiftUI

enum QueryPlanViewMode: String, CaseIterable, Identifiable {
    case diagram
    case tree
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diagram: return String(localized: "Diagram")
        case .tree: return String(localized: "Tree")
        case .raw: return String(localized: "Raw")
        }
    }
}

/// What the pane can actually show for this result, resolved once so the view never has to
/// guess whether a plan is missing because the driver returned nothing or because parsing failed.
enum QueryPlanPresentation {
    case empty
    case parsed(QueryPlan)
    case rawOnly(String)

    enum Kind: Equatable {
        case empty
        case parsed
        case rawOnly
    }

    static func resolve(plan: QueryPlan?, rawText: String) -> QueryPlanPresentation {
        if let plan { return .parsed(plan) }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .empty : .rawOnly(trimmed)
    }

    var kind: Kind {
        switch self {
        case .empty: return .empty
        case .parsed: return .parsed
        case .rawOnly: return .rawOnly
        }
    }

    var plan: QueryPlan? {
        guard case .parsed(let plan) = self else { return nil }
        return plan
    }

    var rawText: String? {
        guard case .rawOnly(let text) = self else { return nil }
        return text
    }
}

struct QueryPlanResultView: View {
    let rawText: String
    let executionTime: TimeInterval?
    let plan: QueryPlan?

    @AppStorage(PreferenceKeys.queryPlanRawFontSize.name) private var fontSize: Double = 13
    @State private var showCopyConfirmation = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var viewMode: QueryPlanViewMode = .diagram

    /// Shared by the diagram and the outline, so switching view mode keeps the selected step.
    @State private var selectedNodeId: UUID?

    private var presentation: QueryPlanPresentation {
        QueryPlanPresentation.resolve(plan: plan, rawText: rawText)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .empty:
            EmptyStateView(
                icon: "chart.bar.doc.horizontal",
                title: String(localized: "No Plan Available"),
                description: String(localized: "This database did not return a query plan for the statement.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .rawOnly(let text):
            VStack(spacing: 0) {
                unparsedBanner
                DDLTextView(ddl: text, fontSize: $fontSize)
            }

        case .parsed(let plan):
            switch viewMode {
            case .diagram:
                QueryPlanDiagramView(plan: plan, selectedNodeId: $selectedNodeId)
            case .tree:
                QueryPlanTreeView(plan: plan, selectedNodeId: $selectedNodeId)
            case .raw:
                DDLTextView(ddl: rawText, fontSize: $fontSize)
            }
        }
    }

    private var unparsedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(String(localized: "This plan could not be read as a tree. Showing the raw output."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            if presentation.plan != nil {
                Picker("", selection: $viewMode) {
                    ForEach(QueryPlanViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 240)
                .labelsHidden()
                .accessibilityIdentifier("query-plan-mode-picker")
            }

            if viewMode == .raw || presentation.plan == nil {
                fontSizeStepper
            }

            timings

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

    private var fontSizeStepper: some View {
        HStack(spacing: 4) {
            Button { fontSize = max(10, fontSize - 1) } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "Decrease font size"))
            Text("\(Int(fontSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Button { fontSize = min(24, fontSize + 1) } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 24, height: 24)
            }
            .accessibilityLabel(String(localized: "Increase font size"))
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var timings: some View {
        if let plan = presentation.plan {
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
        } else if let executionTime {
            Text(formattedDuration(executionTime))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func copyText() {
        ClipboardService.shared.writeText(rawText)
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
