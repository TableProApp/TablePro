//
//  FilterRowView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct FilterRowView: View {
    @Binding var filter: TableFilter
    let columns: [String]
    let completions: [String]
    var caseMatching: FilterCaseMatching = .engine(.unsupported)
    var enumValuesByColumn: [String: [String]] = [:]
    var rawSQLCompletionProvider: RawSQLFilterCompletionProvider?
    var columnMenu: FilterColumnMenu = .empty
    var fieldPaths: [PluginFieldPath] = []
    var offersRawFilter = true
    var rawFilterLabel = String(localized: "Raw SQL")
    var reservesElementScope = false
    let onAdd: () -> Void
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    let onApply: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let isReorderEnabled: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDropFilter: (UUID) -> Void
    @Binding var focusedFilterId: UUID?

    @State private var isDropTargeted = false
    @State private var showNestedPathPicker = false

    static let spacing: CGFloat = 8
    static let horizontalInset: CGFloat = 12

    private let rowButtonGlyphSize: CGFloat = 14
    private static let columnPickerMaximumWidth: CGFloat = 160

    private var pickerEligibleOperators: Set<FilterOperator> {
        [.equal, .notEqual]
    }

    private var rawSQLCompletionSource: FilterCompletionSource {
        if let rawSQLCompletionProvider {
            return .sqlTokens(rawSQLCompletionProvider)
        }
        return .staticValues(completions)
    }

    private var allowedValuesForCurrentColumn: [String]? {
        guard !filter.isRawSQL,
              let values = enumValuesByColumn[filter.columnName],
              !values.isEmpty else { return nil }
        return values
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            dragHandle

            enabledToggle

            Group {
                columnPicker

                elementScopeSlot

                if !filter.isRawSQL {
                    operatorPicker
                }

                HStack(spacing: Self.spacing) {
                    valueFields
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(filter.isEnabled ? 1 : 0.5)

            rowButtons
        }
        .controlSize(.small)
        .frame(minHeight: FilterValueTextField.singleLineHeight(for: .small))
        .padding(.vertical, 5)
        .padding(.horizontal, Self.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropHighlight)
        .dropDestination(for: FilterRowTransfer.self) { items, _ in
            guard let dragged = items.first else { return false }
            onDropFilter(dragged.filterID)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .contextMenu { rowContextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if canMoveUp {
                Button(String(localized: "Move Filter Up"), action: onMoveUp)
            }
            if canMoveDown {
                Button(String(localized: "Move Filter Down"), action: onMoveDown)
            }
        }
    }

    @ViewBuilder
    private var dragHandle: some View {
        if isReorderEnabled {
            FilterRowDragHandle()
                .draggable(FilterRowTransfer(filterID: filter.id)) {
                    dragPreview
                }
        } else {
            Color.clear
                .frame(width: FilterRowDragHandle.gutterWidth, height: 1)
        }
    }

    private var dragPreview: some View {
        HStack(spacing: 4) {
            Text(filter.isRawSQL ? rawFilterLabel : filter.columnName)

            if !filter.isRawSQL {
                Text(filter.filterOperator.symbol.isEmpty
                    ? filter.filterOperator.displayName
                    : filter.filterOperator.symbol)
                    .foregroundStyle(.secondary)
            }

            Text(previewValue)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var previewValue: String {
        guard filter.isRawSQL || filter.filterOperator.requiresValue else { return "" }
        return filter.value
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor.opacity(isDropTargeted ? 0.18 : 0))
    }

    private var enabledToggle: some View {
        Toggle("", isOn: $filter.isEnabled)
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Enable filter"))
            .accessibilityValue(filter.isEnabled ? String(localized: "Active") : String(localized: "Inactive"))
            .help(String(localized: "Include this filter when applying"))
    }

    // A restored filter can name a path not loaded yet, and a Picker matching no tag renders blank.
    private var driftedColumn: String? {
        guard !filter.isRawSQL, !filter.columnName.isEmpty else { return nil }
        return columnMenu.contains(filter.columnName) ? nil : filter.columnName
    }

    private var columnPicker: some View {
        HStack(spacing: 4) {
            IdealWidthCap(maximum: Self.columnPickerMaximumWidth) {
                columnMenuPicker
            }

            if columnMenu.hasMorePaths {
                nestedFieldPathButton
            }
        }
    }

    private var columnMenuPicker: some View {
        Picker(String(localized: "Filter column"), selection: columnSelection) {
            if offersRawFilter || filter.isRawSQL {
                Text(rawFilterLabel).tag(String?.none)
                Divider()
            }
            ForEach(columns, id: \.self) { column in
                Text(column).tag(String?.some(column))
            }
            ForEach(columnMenu.groups) { group in
                Divider()
                ForEach(group.paths, id: \.path) { path in
                    Text(path.path).tag(String?.some(path.path))
                }
            }
            if let driftedColumn {
                Divider()
                Text(driftedColumn).tag(String?.some(driftedColumn))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityValue(filter.isRawSQL ? rawFilterLabel : filter.columnName)
        .help(String(localized: "Select filter column"))
    }

    // Nil is the raw condition, so a table column that shares the raw row's name stays a column.
    private var columnSelection: Binding<String?> {
        Binding(
            get: { filter.isRawSQL ? nil : filter.columnName },
            set: { name in
                filter = name.map(filter.selectingColumn) ?? filter.selectingRawCondition()
            }
        )
    }

    private var nestedFieldPathButton: some View {
        Button {
            showNestedPathPicker = true
        } label: {
            Image(systemName: "list.bullet.indent")
                .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(String(localized: "Nested field path"))
        .accessibilityIdentifier("filter-nested-field-path")
        .help(String(localized: "Filter on a nested field path"))
        .popover(isPresented: $showNestedPathPicker, arrowEdge: .bottom) {
            NestedFieldPathPicker(
                fieldPaths: fieldPaths,
                currentValue: filter.columnName,
                onCommit: { filter = filter.selectingColumn($0) },
                onDismiss: { showNestedPathPicker = false }
            )
        }
    }

    // Another row's scope picker would push this row's operator right, so the slot stays reserved.
    @ViewBuilder
    private var elementScopeSlot: some View {
        if let arrayPrefix {
            elementScopePicker(prefix: arrayPrefix, selection: elementScopeBinding)
                .accessibilityIdentifier("filter-element-scope")
                .help(elementScopeHelp)
        } else if reservesElementScope {
            elementScopePicker(prefix: "-", selection: .constant(""))
                .hidden()
                .accessibilityHidden(true)
        }
    }

    // MongoDB reads two conditions on one array as "any element satisfies each"; binding them to one element is another query.
    private func elementScopePicker(prefix: String, selection: Binding<String>) -> some View {
        Picker(String(localized: "Array element scope"), selection: selection) {
            Text("any element").tag("")
            Text("same element").tag(prefix)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .labelsHidden()
    }

    private var arrayPrefix: String? {
        guard !filter.isRawSQL else { return nil }
        return FilterColumnMenu.elementScope(for: filter.columnName, in: fieldPaths)
    }

    private var elementScopeBinding: Binding<String> {
        Binding(
            get: { filter.elementScope ?? "" },
            set: { filter.elementScope = $0.isEmpty ? nil : $0 }
        )
    }

    private var elementScopeHelp: String {
        guard let prefix = arrayPrefix else { return String(localized: "Array element scope") }
        return filter.elementScope == nil
            ? String(format: String(localized: "Any element of %@ may match this row on its own"), prefix)
            : String(format: String(localized: "Rows set to “same element” must all match one %@ element"), prefix)
    }

    private var operatorPicker: some View {
        IdealWidthCap {
            operatorMenu
        }
    }

    private var operatorMenu: some View {
        Menu {
            Picker(String(localized: "Filter operator"), selection: operatorSelection) {
                ForEach(FilterOperator.allCases) { op in
                    OperatorMenuLabel(op: op).tag(op)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if casePresentation.showsControl {
                Divider()
                Toggle(String(localized: "Match Case"), isOn: $filter.isCaseSensitive)
                    .disabled(!casePresentation.isAdjustable)
                if let reason = casePresentation.fixedReason {
                    Text(reason).disabled(true)
                }
            }
        } label: {
            FilterOperatorMenuTitle(
                filterOperator: filter.filterOperator,
                showsCaseIndicator: casePresentation.showsIndicator,
                reservesCaseIndicator: caseMatching.isAdjustable
            )
            .accessibilityLabel(String(localized: "Filter operator"))
        }
        .menuStyle(.button)
        .accessibilityValue(operatorAccessibilityValue)
        .help(caseSensitivityHelp)
    }

    private var operatorSelection: Binding<FilterOperator> {
        Binding(
            get: { filter.filterOperator },
            set: { filter = filter.selectingOperator($0) }
        )
    }

    private var casePresentation: FilterCaseSensitivityPresentation {
        FilterCaseSensitivityPresentation(
            filterOperator: filter.filterOperator,
            isCaseSensitive: filter.isCaseSensitive,
            matching: caseMatching
        )
    }

    private var caseSensitivityHelp: String {
        let presentation = casePresentation
        guard presentation.showsControl else { return String(localized: "Select filter operator") }
        if let reason = presentation.fixedReason { return reason }
        return filter.isCaseSensitive
            ? String(localized: "Matching is case-sensitive")
            : String(localized: "Matching ignores case")
    }

    private var operatorAccessibilityValue: String {
        guard casePresentation.isAdjustable else { return filter.filterOperator.displayName }
        let caseMode = filter.isCaseSensitive
            ? String(localized: "Match Case")
            : String(localized: "Ignore Case")
        return "\(filter.filterOperator.displayName), \(caseMode)"
    }

    @ViewBuilder
    private var valueFields: some View {
        if filter.isRawSQL {
            FilterValueTextField(
                text: $filter.value,
                focusedId: $focusedFilterId,
                identity: filter.id,
                placeholder: "e.g. id = 1",
                completionSource: rawSQLCompletionSource,
                allowsMultiLine: true,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            .accessibilityLabel(String(localized: "WHERE clause"))
        } else if filter.filterOperator.requiresValue {
            if let allowedValues = allowedValuesForCurrentColumn,
               pickerEligibleOperators.contains(filter.filterOperator) {
                enumValuePicker(allowedValues: allowedValues)
            } else {
                FilterValueTextField(
                    text: $filter.value,
                    focusedId: $focusedFilterId,
                    identity: filter.id,
                    placeholder: String(localized: "Value"),
                    completionSource: .staticValues(completions),
                    onSubmit: onSubmit,
                    onCancel: onCancel
                )
                .accessibilityLabel(String(localized: "Filter value"))
            }

            if filter.filterOperator.requiresSecondValue {
                Text("and")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                FilterValueTextField(
                    text: secondValueBinding,
                    focusedId: $focusedFilterId,
                    identity: FilterValueTextField.secondFieldIdentity(for: filter.id),
                    placeholder: String(localized: "Value"),
                    completionSource: .staticValues(completions),
                    onSubmit: onSubmit,
                    onCancel: onCancel
                )
                .accessibilityLabel(String(localized: "Second filter value"))
            }
        }
    }

    private var secondValueBinding: Binding<String> {
        Binding(
            get: { filter.secondValue ?? "" },
            set: { filter.secondValue = $0 }
        )
    }

    private var rowButtons: some View {
        HStack(spacing: 4) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(String(localized: "Add filter"))
            .help(String(localized: "Add filter row"))

            Button(action: onRemove) {
                Image(systemName: "minus")
                    .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(String(localized: "Remove filter"))
            .help(String(localized: "Remove filter row"))
        }
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button {
            onApply()
        } label: {
            Label(String(localized: "Apply Only This Filter"), systemImage: "checkmark.circle")
        }
        .disabled(!filter.isValid)

        Divider()

        Button {
            onAdd()
        } label: {
            Label(String(localized: "Add Filter"), systemImage: "plus")
        }

        Button {
            onDuplicate()
        } label: {
            Label(String(localized: "Duplicate Filter"), systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            onMoveUp()
        } label: {
            Label(String(localized: "Move Up"), systemImage: "arrow.up")
        }
        .disabled(!canMoveUp)

        Button {
            onMoveDown()
        } label: {
            Label(String(localized: "Move Down"), systemImage: "arrow.down")
        }
        .disabled(!canMoveDown)

        Divider()

        Button(role: .destructive) {
            onRemove()
        } label: {
            Label(String(localized: "Remove Filter"), systemImage: "trash")
        }
    }

    @ViewBuilder
    private func enumValuePicker(allowedValues: [String]) -> some View {
        let isDrift = !filter.value.isEmpty && !allowedValues.contains(filter.value)
        Picker(String(localized: "Filter value"), selection: $filter.value) {
            // An empty value matches no tag, and a pop-up with no selection draws blank.
            if filter.value.isEmpty {
                Text("Value").tag("")
                Divider()
            }
            ForEach(allowedValues, id: \.self) { value in
                Text(value).tag(value)
            }
            if isDrift {
                Divider()
                Text(filter.value).tag(filter.value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private struct OperatorMenuLabel: View {
        let op: FilterOperator

        var body: some View {
            Text(op.symbol.isEmpty ? op.displayName : "\(op.symbol)  \(op.displayName)")
                .accessibilityLabel(op.displayName)
        }
    }
}
