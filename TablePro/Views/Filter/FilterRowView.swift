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
    var caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle = .unsupported
    var enumValuesByColumn: [String: [String]] = [:]
    var rawSQLCompletionProvider: RawSQLFilterCompletionProvider?
    var columnMenu: FilterColumnMenu = .empty
    var fieldPaths: [PluginFieldPath] = []
    var rawFilterLabel = String(localized: "Raw SQL")
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

    private let rowButtonGlyphSize: CGFloat = 14

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
        HStack(spacing: 4) {
            dragHandle

            enabledToggle

            Group {
                columnPicker

                if arrayPrefix != nil {
                    elementScopePicker
                }

                if !filter.isRawSQL {
                    operatorPicker
                }

                valueFields
            }
            .opacity(filter.isEnabled ? 1 : 0.5)

            rowButtons
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
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
        if filter.isRawSQL {
            return filter.rawSQL ?? ""
        }
        guard filter.filterOperator.requiresValue else { return "" }
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

    /// A restored or preset filter can name a path the sample has not returned yet, and a Picker
    /// whose selection matches no tag renders blank and can reset the binding. Carrying the value
    /// as its own item keeps it visible and selected until the paths land.
    private var driftedColumn: String? {
        guard !filter.isRawSQL, !filter.columnName.isEmpty else { return nil }
        return columnMenu.contains(filter.columnName) ? nil : filter.columnName
    }

    private var columnPicker: some View {
        HStack(spacing: 4) {
            Picker("", selection: $filter.columnName) {
                Text(rawFilterLabel).tag(TableFilter.rawSQLColumn)
                Divider()
                ForEach(columns, id: \.self) { column in
                    Text(column).tag(column)
                }
                ForEach(columnMenu.groups) { group in
                    Divider()
                    ForEach(group.paths, id: \.path) { path in
                        Text(path.path).tag(path.path)
                    }
                }
                if let driftedColumn {
                    Divider()
                    Text(driftedColumn).tag(driftedColumn)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .labelsHidden()
            .accessibilityLabel(String(localized: "Filter column"))
            .accessibilityValue(filter.isRawSQL ? rawFilterLabel : filter.columnName)
            .help(String(localized: "Select filter column"))

            if columnMenu.hasMorePaths {
                nestedFieldPathButton
            }
        }
        .onChange(of: filter.columnName) { _, _ in
            filter.elementScope = nil
        }
    }

    private var nestedFieldPathButton: some View {
        Button {
            showNestedPathPicker = true
        } label: {
            Image(systemName: "list.bullet.indent")
                .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(String(localized: "Nested field path"))
        .accessibilityIdentifier("filter-nested-field-path")
        .help(String(localized: "Filter on a nested field path"))
        .popover(isPresented: $showNestedPathPicker, arrowEdge: .bottom) {
            NestedFieldPathPicker(
                fieldPaths: fieldPaths,
                currentValue: filter.columnName,
                onCommit: { filter.columnName = $0 },
                onDismiss: { showNestedPathPicker = false }
            )
        }
    }

    /// MongoDB reads two conditions on the same array as "any element satisfies each", so
    /// binding them to one element is a different query the user has to ask for.
    private var elementScopePicker: some View {
        Picker("", selection: elementScopeBinding) {
            Text("any element").tag("")
            Text("same element").tag(arrayPrefix ?? "")
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .labelsHidden()
        .accessibilityLabel(String(localized: "Array element scope"))
        .accessibilityIdentifier("filter-element-scope")
        .help(elementScopeHelp)
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
        Menu {
            Picker("", selection: $filter.filterOperator) {
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
            operatorMenuTitle
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(String(localized: "Filter operator"))
        .accessibilityValue(operatorAccessibilityValue)
        .help(caseSensitivityHelp)
    }

    @ViewBuilder
    private var operatorMenuTitle: some View {
        HStack(spacing: 3) {
            OperatorMenuLabel(op: filter.filterOperator)
            if casePresentation.showsIndicator {
                Image(systemName: "textformat")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var casePresentation: FilterCaseSensitivityPresentation {
        FilterCaseSensitivityPresentation(
            filterOperator: filter.filterOperator,
            isCaseSensitive: filter.isCaseSensitive,
            style: caseSensitivityStyle
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
                text: Binding(
                    get: { filter.rawSQL ?? "" },
                    set: { filter.rawSQL = $0 }
                ),
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
                .frame(minWidth: 80)
                .accessibilityLabel(String(localized: "Filter value"))
            }

            if filter.filterOperator.requiresSecondValue {
                Text("and")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Value", text: Binding(
                    get: { filter.secondValue ?? "" },
                    set: { filter.secondValue = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.callout)
                .autocorrectionDisabled(true)
                .frame(minWidth: 80)
                .accessibilityLabel(String(localized: "Second filter value"))
                .onSubmit { onSubmit() }
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    private var rowButtons: some View {
        HStack(spacing: 4) {
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Add filter"))
            .help(String(localized: "Add filter row"))

            Button(action: onRemove) {
                Image(systemName: "minus")
                    .frame(width: rowButtonGlyphSize, height: rowButtonGlyphSize)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
        Picker("", selection: $filter.value) {
            ForEach(allowedValues, id: \.self) { value in
                Text(value).tag(value)
            }
            if isDrift {
                Divider()
                Text(filter.value).tag(filter.value)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(minWidth: 100)
        .labelsHidden()
        .accessibilityLabel(String(localized: "Filter value"))
    }

    private struct OperatorMenuLabel: View {
        let op: FilterOperator

        var body: some View {
            Text(op.symbol.isEmpty ? op.displayName : "\(op.symbol)  \(op.displayName)")
                .accessibilityLabel(op.displayName)
        }
    }
}
