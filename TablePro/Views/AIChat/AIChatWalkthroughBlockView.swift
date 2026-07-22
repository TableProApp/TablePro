//
//  AIChatWalkthroughBlockView.swift
//  TablePro
//

import SwiftUI

struct AIChatWalkthroughBlockView: View {
    @Bindable var block: ChatContentBlock

    @Environment(AIChatViewModel.self) private var viewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusedValue(\.commandActions) private var focusedActions
    @Bindable private var commandRegistry = CommandActionsRegistry.shared

    @State private var expandedStepIDs: Set<UUID> = []
    @State private var activeAnchor: SqlWalkthroughAnchor?
    @State private var scrollTarget: Int?
    @State private var highlightClearTask: Task<Void, Never>?
    @State private var activeFollowUpStepID: UUID?
    @State private var followUpText: String = ""
    @State private var showApplyConfirmation = false

    private static let maxDiffLines = 500

    private var actions: MainContentCommandActions? {
        focusedActions ?? commandRegistry.current
    }

    private var walkthrough: SqlWalkthroughBlock? {
        if case .sqlWalkthrough(let value) = block.kind { return value }
        return nil
    }

    var body: some View {
        if let walkthrough {
            content(for: walkthrough)
        }
    }

    @ViewBuilder
    private func content(for walkthrough: SqlWalkthroughBlock) -> some View {
        let beforeLines = SqlNormalizer.lines(walkthrough.beforeSQL)
        let afterLines = walkthrough.envelope.afterSQL.map(SqlNormalizer.lines) ?? []

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                header(for: walkthrough)
                Divider()
                if walkthrough.hasDiff {
                    diffSection(for: walkthrough, beforeLines: beforeLines, afterLines: afterLines)
                } else {
                    sourceListing(beforeLines)
                }
                if !walkthrough.envelope.steps.isEmpty {
                    Divider()
                    stepList(walkthrough.envelope.steps, beforeLines: beforeLines, afterLines: afterLines)
                }
                if let afterSQL = walkthrough.envelope.afterSQL, !afterSQL.isEmpty {
                    applyControls(afterSQL: afterSQL)
                }
            }
            .padding(10)
        }
        .onAppear { autoExpandFirstStep(walkthrough.envelope.steps) }
        .onDisappear {
            highlightClearTask?.cancel()
            highlightClearTask = nil
        }
    }

    private func header(for walkthrough: SqlWalkthroughBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label(String(localized: "AI Walkthrough"), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("AI-generated. Review before applying.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if walkthrough.hasDiff {
                Picker(String(localized: "Diff layout"), selection: diffStyleBinding) {
                    Text("Unified").tag(SqlWalkthroughDiffStyle.unified)
                    Text("Split").tag(SqlWalkthroughDiffStyle.split)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(String(localized: "Diff layout"))
            }
        }
    }

    @ViewBuilder
    private func diffSection(
        for walkthrough: SqlWalkthroughBlock,
        beforeLines: [String],
        afterLines: [String]
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    switch walkthrough.diffStyle {
                    case .unified:
                        unifiedDiff(before: beforeLines, after: afterLines)
                    case .split:
                        splitDiff(before: beforeLines, after: afterLines)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withMotion { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private func unifiedDiff(before: [String], after: [String]) -> some View {
        let lines = Array(DiffComputer.computeUnified(before: before, after: after).prefix(Self.maxDiffLines))
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                unifiedRow(line)
                    .id(line.id)
            }
            truncationFooter(shown: lines.count, total: max(before.count, after.count))
        }
    }

    private func unifiedRow(_ line: DiffUnifiedLine) -> some View {
        let marker: String = switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        }
        let tint: Color? = switch line.kind {
        case .added: .green.opacity(0.16)
        case .removed: .red.opacity(0.16)
        case .context: nil
        }
        let statusLabel: String = switch line.kind {
        case .added: String(localized: "Added")
        case .removed: String(localized: "Removed")
        case .context: String(localized: "Unchanged")
        }
        return HStack(alignment: .top, spacing: 8) {
            Text(verbatim: marker)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(rowBackground(base: tint, unified: line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(statusLabel): \(line.text)"))
    }

    private struct SplitRow: Identifiable {
        let id: Int
        let text: String?
        let kind: DiffPair.Kind
        let lineNumber: Int?
    }

    private func splitDiff(before: [String], after: [String]) -> some View {
        let pairs = Array(DiffComputer.computeSplit(before: before, after: after).prefix(Self.maxDiffLines))
        return HStack(alignment: .top, spacing: 0) {
            splitColumn(rows: splitRows(pairs, side: .before), side: .before)
            Divider()
            splitColumn(rows: splitRows(pairs, side: .after), side: .after)
        }
    }

    private func splitRows(_ pairs: [DiffPair], side: SqlWalkthroughAnchor.Side) -> [SplitRow] {
        var rows: [SplitRow] = []
        var lineNumber = 0
        for (index, pair) in pairs.enumerated() {
            let text = side == .before ? pair.before : pair.after
            if text != nil { lineNumber += 1 }
            rows.append(SplitRow(id: index, text: text, kind: pair.kind, lineNumber: text == nil ? nil : lineNumber))
        }
        return rows
    }

    private func splitColumn(rows: [SplitRow], side: SqlWalkthroughAnchor.Side) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                splitRow(row, side: side)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func splitRow(_ row: SplitRow, side: SqlWalkthroughAnchor.Side) -> some View {
        let tint: Color? = switch (row.kind, side) {
        case (.removed, .before), (.changed, .before): .red.opacity(0.16)
        case (.added, .after), (.changed, .after): .green.opacity(0.16)
        default: nil
        }
        return HStack(alignment: .top, spacing: 6) {
            Text(row.text ?? " ")
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(splitRowBackground(base: tint, side: side, lineNumber: row.lineNumber))
    }

    private func sourceListing(_ lines: [String]) -> some View {
        let capped = Array(lines.prefix(Self.maxDiffLines))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(capped.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top, spacing: 8) {
                            Text(verbatim: "\(index + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
                            Text(text.isEmpty ? " " : text)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(index + 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(sourceRowBackground(lineNumber: index + 1))
                    }
                    truncationFooter(shown: capped.count, total: lines.count)
                }
            }
            .frame(maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withMotion { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    private func stepList(
        _ steps: [SqlWalkthroughStep],
        beforeLines: [String],
        afterLines: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, index: index, beforeLines: beforeLines, afterLines: afterLines)
            }
        }
    }

    private func stepRow(
        _ step: SqlWalkthroughStep,
        index: Int,
        beforeLines: [String],
        afterLines: [String]
    ) -> some View {
        let anchor = resolvedAnchor(step.anchor, beforeCount: beforeLines.count, afterCount: afterLines.count)
        return DisclosureGroup(isExpanded: stepBinding(step.id)) {
            VStack(alignment: .leading, spacing: 6) {
                if !step.why.isEmpty {
                    Text(step.why)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let anchor, let snippet = anchorSnippet(anchor, beforeLines: beforeLines, afterLines: afterLines) {
                    anchoredSnippet(snippet)
                    Button(String(localized: "Jump to lines")) { activateAnchor(anchor) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                followUpControls(for: step, index: index)
            }
            .padding(.top, 4)
        } label: {
            stepLabel(step, index: index, anchored: anchor != nil)
        }
    }

    private func stepLabel(_ step: SqlWalkthroughStep, index: Int, anchored: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "\(min(index + 1, 50)).circle.fill")
                .foregroundStyle(.secondary)
            ImportancePillView(importance: step.importance)
            Text(step.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
            Spacer()
            if anchored {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(String(localized: "Step")) \(index + 1): \(step.title)"))
    }

    private func anchoredSnippet(_ snippet: String) -> some View {
        Text(snippet)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func followUpControls(for step: SqlWalkthroughStep, index: Int) -> some View {
        Button {
            followUpText = ""
            activeFollowUpStepID = step.id
        } label: {
            Label(String(localized: "Ask about this change"), systemImage: "bubble.and.pencil")
                .font(.caption)
        }
        .buttonStyle(.link)
        .disabled(viewModel.isStreaming)
        .popover(isPresented: followUpBinding(step.id), arrowEdge: .leading) {
            followUpPopover(for: step, index: index)
        }
    }

    private func followUpPopover(for step: SqlWalkthroughStep, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: String(localized: "Ask about step %d"), index + 1))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(String(localized: "Ask about this change…"), text: $followUpText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .frame(width: 240)
                .onSubmit { submitFollowUp(for: step, index: index) }
            HStack {
                Spacer()
                Button(String(localized: "Ask")) { submitFollowUp(for: step, index: index) }
                    .buttonStyle(.borderedProminent)
                    .disabled(followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func applyControls(afterSQL: String) -> some View {
        HStack {
            Spacer()
            Button(String(localized: "Apply to Editor")) { showApplyConfirmation = true }
                .controlSize(.small)
                .disabled(actions == nil)
                .help(actions == nil
                    ? String(localized: "Open a connection to apply")
                    : String(localized: "Replace the editor content with the suggested SQL"))
        }
        .alert(String(localized: "Apply suggested SQL?"), isPresented: $showApplyConfirmation) {
            Button(String(localized: "Apply")) { actions?.loadQueryIntoEditor(afterSQL) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("This replaces the editor content with the AI-generated SQL.")
        }
    }

    @ViewBuilder
    private func truncationFooter(shown: Int, total: Int) -> some View {
        if total > shown {
            Text(String(format: String(localized: "…and %d more lines"), total - shown))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Backgrounds

    private func rowBackground(base: Color?, unified line: DiffUnifiedLine) -> Color {
        if let anchor = activeAnchor, unifiedLineMatches(line, anchor: anchor) {
            return .yellow.opacity(0.28)
        }
        return base ?? .clear
    }

    private func splitRowBackground(base: Color?, side: SqlWalkthroughAnchor.Side, lineNumber: Int?) -> Color {
        if let anchor = activeAnchor, let lineNumber, splitLineMatches(side: side, lineNumber: lineNumber, anchor: anchor) {
            return .yellow.opacity(0.28)
        }
        return base ?? .clear
    }

    private func sourceRowBackground(lineNumber: Int) -> Color {
        if let anchor = activeAnchor, anchor.side != .after,
           lineNumber >= anchor.startLine, lineNumber <= anchor.endLine {
            return .yellow.opacity(0.28)
        }
        return .clear
    }

    // MARK: - Anchor helpers

    private func resolvedAnchor(_ anchor: SqlWalkthroughAnchor?, beforeCount: Int, afterCount: Int) -> SqlWalkthroughAnchor? {
        guard let anchor, anchor.isValid(beforeLineCount: beforeCount, afterLineCount: afterCount) else { return nil }
        return anchor
    }

    private func anchorSnippet(_ anchor: SqlWalkthroughAnchor, beforeLines: [String], afterLines: [String]) -> String? {
        let source = anchor.side == .after ? afterLines : beforeLines
        guard anchor.startLine >= 1, anchor.endLine <= source.count else { return nil }
        let slice = source[(anchor.startLine - 1)..<anchor.endLine]
        let joined = slice.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func unifiedLineMatches(_ line: DiffUnifiedLine, anchor: SqlWalkthroughAnchor) -> Bool {
        func inRange(_ number: Int?) -> Bool {
            guard let number else { return false }
            return number >= anchor.startLine && number <= anchor.endLine
        }
        switch anchor.side {
        case .before: return inRange(line.beforeLineNumber)
        case .after: return inRange(line.afterLineNumber)
        case .both: return inRange(line.beforeLineNumber) || inRange(line.afterLineNumber)
        }
    }

    private func splitLineMatches(side: SqlWalkthroughAnchor.Side, lineNumber: Int, anchor: SqlWalkthroughAnchor) -> Bool {
        let sideMatches = anchor.side == .both || anchor.side == side
        guard sideMatches else { return false }
        return lineNumber >= anchor.startLine && lineNumber <= anchor.endLine
    }

    private func activateAnchor(_ anchor: SqlWalkthroughAnchor) {
        activeAnchor = anchor
        scrollTarget = unifiedScrollTarget(for: anchor)
        highlightClearTask?.cancel()
        highlightClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withMotion { activeAnchor = nil }
        }
    }

    private func unifiedScrollTarget(for anchor: SqlWalkthroughAnchor) -> Int? {
        guard let walkthrough, walkthrough.hasDiff else { return anchor.startLine }
        let before = SqlNormalizer.lines(walkthrough.beforeSQL)
        let after = walkthrough.envelope.afterSQL.map(SqlNormalizer.lines) ?? []
        let lines = DiffComputer.computeUnified(before: before, after: after)
        return lines.first { unifiedLineMatches($0, anchor: anchor) }?.id
    }

    // MARK: - Bindings & actions

    private var diffStyleBinding: Binding<SqlWalkthroughDiffStyle> {
        Binding(
            get: { walkthrough?.diffStyle ?? .unified },
            set: { newValue in
                guard var updated = walkthrough else { return }
                updated.diffStyle = newValue
                block.setKind(.sqlWalkthrough(updated))
            }
        )
    }

    private func stepBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedStepIDs.contains(id) },
            set: { isOpen in
                if isOpen { expandedStepIDs.insert(id) } else { expandedStepIDs.remove(id) }
            }
        )
    }

    private func followUpBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { activeFollowUpStepID == id },
            set: { isShown in
                if isShown { activeFollowUpStepID = id } else if activeFollowUpStepID == id { activeFollowUpStepID = nil }
            }
        )
    }

    private func submitFollowUp(for step: SqlWalkthroughStep, index: Int) {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeFollowUpStepID = nil
        followUpText = ""
        let prompt = String(
            format: String(localized: "Follow-up on step %d \"%@\" (%@): %@"),
            index + 1,
            step.title,
            step.why,
            trimmed
        )
        viewModel.sendWithContext(prompt: prompt)
    }

    private func autoExpandFirstStep(_ steps: [SqlWalkthroughStep]) {
        guard expandedStepIDs.isEmpty, let first = steps.first else { return }
        expandedStepIDs.insert(first.id)
    }

    private func withMotion(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { change() }
        }
    }
}

private struct ImportancePillView: View {
    let importance: SqlWalkthroughImportance

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .accessibilityLabel(Text(verbatim: "\(String(localized: "Importance")): \(label)"))
    }

    private var label: String {
        switch importance {
        case .critical: String(localized: "Critical")
        case .normal: String(localized: "Change")
        case .context: String(localized: "Context")
        }
    }

    private var color: Color {
        switch importance {
        case .critical: .red
        case .normal: .accentColor
        case .context: .secondary
        }
    }
}
