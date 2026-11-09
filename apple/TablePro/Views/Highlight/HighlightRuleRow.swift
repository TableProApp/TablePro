//
//  HighlightRuleRow.swift
//  TablePro
//

import SwiftUI

struct HighlightRuleRow: View {
    @Binding var rule: HighlightRule
    let columnOptions: [HighlightColumnOption]
    @Binding var focusedRuleID: UUID?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onRemove: () -> Void
    let onCancel: () -> Void

    // Narrower than the filter bar's 160: a row gets 523pt inside this popover's list.
    private static let columnPickerMaximumWidth: CGFloat = 140

    private var isColumnMissing: Bool {
        !columnOptions.contains { $0.name == rule.columnName && $0.occurrence == rule.columnOccurrence }
    }

    private var warning: HighlightRuleWarning? {
        HighlightRuleWarning.warning(for: rule, isColumnPresent: !isColumnMissing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle("", isOn: $rule.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel(String(localized: "Enable rule"))
                    .accessibilityIdentifier("highlight-rule-enabled")
                    .help(String(localized: "Apply this rule"))
                conditionEditor
                    .opacity(rule.isEnabled ? 1 : 0.5)
            }
            HStack(spacing: 8) {
                colorPicker
                targetPicker
                if let warning {
                    Label(warning.label, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(warning.help)
                        .accessibilityIdentifier("highlight-rule-warning")
                }
                Spacer(minLength: 0)
                removeButton
            }
            .padding(.leading, 22)
            .opacity(rule.isEnabled ? 1 : 0.5)
        }
        .controlSize(.small)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HighlightRuleDescription.condition(of: rule))
        .accessibilityActions {
            if canMoveUp {
                Button(String(localized: "Move Rule Up"), action: onMoveUp)
            }
            if canMoveDown {
                Button(String(localized: "Move Rule Down"), action: onMoveDown)
            }
        }
    }

    private var conditionEditor: some View {
        FilterRowLayout(spacing: 6, fillMinimum: FilterRowView.valueCellMinimumWidth(spacing: 6)) {
            columnPicker
                .fillsReservedWidth()
                .filterRowRole(.reserved(columnCellWidth, minimum: FilterControlMetrics.popUpMinimumWidth))
            operatorMenu
                .fillsReservedWidth()
                .filterRowRole(.reserved(
                    FilterControlMetrics.operatorWidth(reservesCaseIndicator: true),
                    minimum: FilterControlMetrics.operatorMinimumWidth(reservesCaseIndicator: true)
                ))
            HStack(spacing: 6) {
                valueFields
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .filterRowRole(.fill)
        }
        .frame(minHeight: FilterValueTextField.singleLineHeight(for: .small))
    }

    private var columnCellWidth: CGFloat {
        min(FilterControlMetrics.popUpWidth(titles: columnOptions.map(\.label)), Self.columnPickerMaximumWidth)
    }

    private var columnSelection: Binding<String> {
        Binding(
            get: { HighlightColumnOption.identifier(name: rule.columnName, occurrence: rule.columnOccurrence) },
            set: { identifier in
                guard let option = columnOptions.first(where: { $0.id == identifier }) else { return }
                rule = rule.selectingColumn(named: option.name, occurrence: option.occurrence)
            }
        )
    }

    private var columnPicker: some View {
        Picker(String(localized: "Rule column"), selection: columnSelection) {
            ForEach(columnOptions) { option in
                Text(option.label).tag(option.id)
            }
            if isColumnMissing {
                Divider()
                Text(rule.columnName)
                    .tag(HighlightColumnOption.identifier(name: rule.columnName, occurrence: rule.columnOccurrence))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityValue(rule.columnName)
        .accessibilityIdentifier("highlight-rule-column")
        .help(rule.columnName)
    }

    private var operatorSelection: Binding<FilterOperator> {
        Binding(
            get: { rule.filterOperator },
            set: { newOperator in
                rule = rule.selectingOperator(newOperator)
            }
        )
    }

    private var operatorMenu: some View {
        Menu {
            Picker("", selection: operatorSelection) {
                ForEach(FilterOperator.allCases) { filterOperator in
                    Text(Self.operatorLabel(filterOperator))
                        .accessibilityLabel(filterOperator.displayName)
                        .tag(filterOperator)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if rule.filterOperator.supportsCaseSensitivity {
                Divider()
                Toggle(String(localized: "Match Case"), isOn: $rule.isCaseSensitive)
            }
        } label: {
            HStack(spacing: FilterControlMetrics.caseIndicatorSpacing) {
                Text(rule.filterOperator.displayName)
                if rule.filterOperator.supportsCaseSensitivity,
                   rule.isCaseSensitive != rule.filterOperator.defaultIsCaseSensitive {
                    Image(systemName: "textformat")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel(String(localized: "Rule operator"))
        }
        .menuStyle(.button)
        .accessibilityValue(rule.filterOperator.displayName)
        .accessibilityIdentifier("highlight-rule-operator")
    }

    @ViewBuilder
    private var valueFields: some View {
        if rule.filterOperator.requiresValue {
            FilterValueTextField(
                text: $rule.value,
                focusedId: $focusedRuleID,
                identity: rule.id,
                placeholder: String(localized: "Value"),
                onCancel: onCancel
            )
            .frame(minWidth: FilterRowView.valueFieldMinimumWidth)
            .accessibilityLabel(String(localized: "Rule value"))

            if rule.filterOperator.requiresSecondValue {
                Text("and")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                FilterValueTextField(
                    text: Binding(
                        get: { rule.secondValue ?? "" },
                        set: { rule.secondValue = $0 }
                    ),
                    focusedId: $focusedRuleID,
                    identity: FilterValueTextField.secondFieldIdentity(for: rule.id),
                    placeholder: String(localized: "Value"),
                    onCancel: onCancel
                )
                .frame(minWidth: FilterRowView.valueFieldMinimumWidth)
                .accessibilityLabel(String(localized: "Second rule value"))
            }
        }
    }

    private var colorPicker: some View {
        Picker(String(localized: "Highlight color"), selection: $rule.color) {
            ForEach(HighlightColor.allCases) { color in
                Label {
                    Text(color.displayName)
                } icon: {
                    Image(nsImage: color.swatchImage())
                }
                .tag(color)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .labelsHidden()
        .accessibilityValue(rule.color.displayName)
    }

    private var targetPicker: some View {
        Picker("", selection: $rule.target) {
            ForEach(HighlightTarget.allCases) { target in
                Text(target.displayName).tag(target)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(String(localized: "Apply To"))
        .help(String(localized: "Color the whole row, or only the matching cell"))
    }

    private var removeButton: some View {
        Button(String(localized: "Remove Rule"), systemImage: "minus", action: onRemove)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .help(String(localized: "Remove this rule"))
    }

    private static func operatorLabel(_ filterOperator: FilterOperator) -> String {
        filterOperator.symbol.isEmpty
            ? filterOperator.displayName
            : "\(filterOperator.symbol)  \(filterOperator.displayName)"
    }
}
