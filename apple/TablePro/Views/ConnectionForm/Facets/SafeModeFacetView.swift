import SwiftUI

struct SafeModeFacetView: View {
    @ObservedObject var store: ConnectionEditorStore

    @FocusState private var focusedRule: UUID?

    var body: some View {
        Form {
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows, id: \.self) { row in
                        rowView(row)
                    }
                } header: {
                    if let title = section.title {
                        Text(verbatim: title)
                    }
                } footer: {
                    if let footer = section.footer {
                        Text(verbatim: footer)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var sections: [SectionLayout] {
        store.layout.facet(.safeMode)?.sections ?? []
    }

    @ViewBuilder
    private func rowView(_ row: EditorRow) -> some View {
        switch row {
        case .builtIn(.safeModeLevel):
            safeModeLevelRow(row)
        case .builtIn(.manualCommit):
            Toggle(isOn: store.manualCommitBinding) {
                EditorRowLabel(String(localized: "Manual Commit"), row: row, store: store)
            }
            .disabled(!store.traits.manualCommitAvailable)
            .accessibilityIdentifier(row.accessibilityIdentifier)
        case .builtIn(.maskingRules):
            maskingRuleRows
        case .plugin(let fieldID):
            PluginFieldRow(fieldID: fieldID, store: store)
        default:
            EmptyView()
        }
    }

    // A floor that allows one level leaves nothing to pick; the section footer says why.
    @ViewBuilder
    private func safeModeLevelRow(_ row: EditorRow) -> some View {
        let levels = store.allowedSafeModeLevels
        if levels.count == 1 {
            LabeledContent {
                Text(verbatim: store.effectiveSafeModeLevel.displayName)
                    .accessibilityIdentifier(row.accessibilityIdentifier)
            } label: {
                EditorRowLabel(String(localized: "Safe Mode"), row: row, store: store)
            }
        } else {
            Picker(selection: store.safeModeLevelBinding) {
                ForEach(levels) { level in
                    Text(verbatim: level.displayName).tag(level)
                }
            } label: {
                EditorRowLabel(String(localized: "Safe Mode"), row: row, store: store)
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
        }
    }

    @ViewBuilder
    private var maskingRuleRows: some View {
        let rules = store.draft.safety.maskingRules
        ForEach(rules) { rule in
            SafeModeMaskingRuleRow(
                rule: store.maskingRuleBinding(rule.id),
                focusedRule: $focusedRule,
                onRemove: { store.removeMaskingRule(id: rule.id) }
            )
        }
        LabeledContent {
            Button(String(localized: "Add Rule")) {
                let id = store.addMaskingRule()
                // The new row is not in the form until the next update.
                DispatchQueue.main.async { focusedRule = id }
            }
            .accessibilityIdentifier("connection-form-add-masking-rule")
        } label: {
            if rules.isEmpty {
                Text(String(localized: "No Masking Rules"))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SafeModeMaskingRuleRow: View {
    @Binding var rule: MaskingRule
    let focusedRule: FocusState<UUID?>.Binding
    let onRemove: () -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text(String(localized: "Pattern"))
                    .gridColumnAlignment(.trailing)
                TextField(
                    String(localized: "Pattern"),
                    text: $rule.pattern,
                    prompt: Text(verbatim: rule.target == .column ? "*.email" : "uuid")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused(focusedRule, equals: rule.id)
                .accessibilityIdentifier("connection-form-masking-pattern")
                Button(String(localized: "Remove"), action: onRemove)
            }
            GridRow {
                Text(String(localized: "Match"))
                HStack(spacing: 16) {
                    Picker(String(localized: "Match"), selection: $rule.target) {
                        ForEach(MaskingTarget.allCases) { target in
                            Text(verbatim: target.displayName).tag(target)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Picker(String(localized: "Mask"), selection: $rule.style) {
                        ForEach(MaskingStyle.allCases) { style in
                            Text(verbatim: style.displayName).tag(style)
                        }
                    }
                    .fixedSize()
                }
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            }
        }
        .accessibilityElement(children: .contain)
    }
}
