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
                            .id(row)
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
        .scrollsToEditorFocus(.safeMode, store: store)
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
            Toggle(isOn: store.tracking(store.manualCommitBinding, row: row)) {
                EditorRowLabel(String(localized: "Manual Commit"), row: row, store: store)
            }
            .disabled(!store.traits.manualCommitAvailable)
            .accessibilityIdentifier(row.accessibilityIdentifier)
            .editorRowFocus(row, store: store)
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
            .editorRowFocus(row, store: store)
        } else {
            Picker(selection: store.tracking(store.safeModeLevelBinding, row: row)) {
                ForEach(levels) { level in
                    Text(verbatim: level.displayName).tag(level)
                }
            } label: {
                EditorRowLabel(String(localized: "Safe Mode"), row: row, store: store)
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
            .editorRowFocus(row, store: store)
        }
    }

    @ViewBuilder
    private var maskingRuleRows: some View {
        let rules = store.draft.safety.maskingRules
        ForEach(rules) { rule in
            SafeModeMaskingRuleRow(
                rule: store.tracking(store.maskingRuleBinding(rule.id), row: .builtIn(.maskingRules)),
                focusedRule: $focusedRule,
                onRemove: {
                    store.noteEdited(.builtIn(.maskingRules))
                    store.removeMaskingRule(id: rule.id)
                }
            )
        }
        LabeledContent {
            Button(String(localized: "Add Rule")) {
                store.noteEdited(.builtIn(.maskingRules))
                let id = store.addMaskingRule()
                // The new row is not in the form until the next update.
                DispatchQueue.main.async { focusedRule = id }
            }
            .accessibilityIdentifier("connection-form-add-masking-rule")
        } label: {
            if rules.isEmpty {
                Text(String(localized: "No Masking Rules"))
                    .foregroundStyle(.secondary)
            } else {
                Text("^[\(rules.count) Rule](inflect: true)")
            }
        }
        .onEditorFocusRequest(.builtIn(.maskingRules), store: store) {
            focusedRule = store.draft.safety.maskingRules.first?.id
        }
    }
}

// The pattern sits in the label column, so a rule lines up with the rows around it, and only it stretches; the two
// pop-ups and Remove trail it.
private struct SafeModeMaskingRuleRow: View {
    @Binding var rule: MaskingRule
    let focusedRule: FocusState<UUID?>.Binding
    let onRemove: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(String(localized: "Match"), selection: $rule.target) {
                    ForEach(MaskingTarget.allCases) { target in
                        Text(verbatim: target.displayName).tag(target)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(String(localized: "Match the pattern against column names or column types"))
                .accessibilityLabel(String(localized: "Match"))
                .accessibilityIdentifier("connection-form-masking-target")

                Picker(String(localized: "Mask"), selection: $rule.style) {
                    ForEach(MaskingStyle.allCases) { style in
                        Text(verbatim: style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(String(localized: "How matching values are hidden"))
                .accessibilityLabel(String(localized: "Mask"))
                .accessibilityIdentifier("connection-form-masking-style")

                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Remove Rule"))
                .accessibilityLabel(String(localized: "Remove Rule"))
                .accessibilityIdentifier("connection-form-masking-remove")
            }
        } label: {
            TextField(
                String(localized: "Pattern"),
                text: $rule.pattern,
                prompt: Text(verbatim: rule.target == .column ? "*.email" : "uuid")
            )
            .labelsHidden()
            .autocorrectionDisabled()
            .focused(focusedRule, equals: rule.id)
            .accessibilityLabel(String(localized: "Pattern"))
            .accessibilityIdentifier("connection-form-masking-pattern")
        }
        .accessibilityElement(children: .contain)
    }
}
