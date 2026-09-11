//
//  HighlightRulesPopover.swift
//  TablePro
//

import SwiftUI

struct HighlightRulesPopover: View {
    let columns: [String]
    let rules: [HighlightRule]
    let isPersisted: Bool
    let onChange: ([HighlightRule]) -> Void

    @State private var focusedRuleID: UUID?
    @Environment(\.dismiss) private var dismiss

    private static let rowHeight: CGFloat = 64
    private static let maximumListHeight: CGFloat = 420

    private var columnOptions: [HighlightColumnOption] {
        HighlightColumnOption.options(for: columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if rules.isEmpty {
                emptyState
            } else {
                ruleList
            }
            Divider()
            footer
        }
        .frame(width: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Highlight Rules")
                .font(.headline)
            Text("Rules are checked in order. The first match sets the color.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "No Highlight Rules"), systemImage: "highlighter")
        } description: {
            Text("Right-click a cell and choose Highlight to color rows by value.")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var ruleList: some View {
        List {
            ForEach(rules) { rule in
                HighlightRuleRow(
                    rule: binding(for: rule),
                    columnOptions: columnOptions,
                    focusedRuleID: $focusedRuleID,
                    canMoveUp: rules.first?.id != rule.id,
                    canMoveDown: rules.last?.id != rule.id,
                    onMoveUp: { move(rule, by: -1) },
                    onMoveDown: { move(rule, by: 1) },
                    onRemove: { remove(rule) },
                    onCancel: close
                )
            }
            .onMove(perform: move)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: min(CGFloat(rules.count) * Self.rowHeight + 8, Self.maximumListHeight))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Add Rule"), systemImage: "plus", action: addRule)
                .controlSize(.small)
                .disabled(columns.isEmpty)
                .accessibilityIdentifier("highlight-rules-add")

            Spacer(minLength: 8)

            if !isPersisted {
                Text("Rules for this query result are not saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func binding(for rule: HighlightRule) -> Binding<HighlightRule> {
        Binding(
            get: { rules.first { $0.id == rule.id } ?? rule },
            set: { updated in
                var next = rules
                guard let index = next.firstIndex(where: { $0.id == updated.id }) else { return }
                next[index] = updated
                onChange(next)
            }
        )
    }

    private func addRule() {
        guard let first = columnOptions.first else { return }
        let rule = HighlightRule(columnName: first.name, columnOccurrence: first.occurrence)
        onChange(rules + [rule])
        focusedRuleID = rule.id
    }

    private func close() {
        dismiss()
    }

    private func remove(_ rule: HighlightRule) {
        onChange(rules.filter { $0.id != rule.id })
    }

    private func move(from source: IndexSet, to destination: Int) {
        var next = rules
        next.move(fromOffsets: source, toOffset: destination)
        onChange(next)
    }

    private func move(_ rule: HighlightRule, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        var next = rules
        next.swapAt(index, target)
        onChange(next)
    }
}
