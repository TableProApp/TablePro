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

    /// Bounded rather than `.fixedSize()`. A pull-down takes the width of its widest menu item,
    /// and the items here are the table's column names, so one long name pushed the BETWEEN
    /// second value field past the popover's edge: measured, a 29-character name puts the row at
    /// 582pt and a 62-character one at 791pt, against the 523pt a row actually gets inside this
    /// popover's 540pt list. Capped, both measure 511pt. The filter bar's own 160 does not fit
    /// here, because that row lives in a wider host.
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
        HStack(spacing: 6) {
            columnPicker
            operatorMenu
            valueFields
        }
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
        Picker("", selection: columnSelection) {
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
        .controlSize(.small)
        .frame(maxWidth: Self.columnPickerMaximumWidth)
        .labelsHidden()
        .accessibilityLabel(String(localized: "Rule column"))
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
            HStack(spacing: 3) {
                Text(Self.operatorLabel(rule.filterOperator))
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
        .controlSize(.small)
        .fixedSize()
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
            .frame(minWidth: 90)
            .accessibilityLabel(String(localized: "Rule value"))

            if rule.filterOperator.requiresSecondValue {
                Text("and")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Value", text: Binding(
                    get: { rule.secondValue ?? "" },
                    set: { rule.secondValue = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .autocorrectionDisabled(true)
                .frame(minWidth: 70)
                .accessibilityLabel(String(localized: "Second rule value"))
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private var colorPicker: some View {
        Picker("", selection: $rule.color) {
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
        .controlSize(.small)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(String(localized: "Highlight color"))
        .accessibilityValue(rule.color.displayName)
    }

    private var targetPicker: some View {
        Picker("", selection: $rule.target) {
            ForEach(HighlightTarget.allCases) { target in
                Text(target.displayName).tag(target)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(String(localized: "Apply To"))
        .help(String(localized: "Color the whole row, or only the matching cell"))
    }

    private var removeButton: some View {
        Button(String(localized: "Remove Rule"), systemImage: "minus", action: onRemove)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(String(localized: "Remove this rule"))
    }

    private static func operatorLabel(_ filterOperator: FilterOperator) -> String {
        filterOperator.symbol.isEmpty
            ? filterOperator.displayName
            : "\(filterOperator.symbol)  \(filterOperator.displayName)"
    }
}
