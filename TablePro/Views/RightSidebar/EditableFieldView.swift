//
//  EditableFieldView.swift
//  TablePro
//
//  Compact, type-aware field editor for right sidebar.
//  Two-line layout: field name + type badge, then native editor + menu.
//

import SwiftUI

/// Compact editable field view using native macOS components
struct EditableFieldView: View {
    let columnName: String
    let columnTypeEnum: ColumnType
    let isLongText: Bool
    @Binding var value: String
    let originalValue: String?
    let hasMultipleValues: Bool
    let isPendingNull: Bool
    let isPendingDefault: Bool
    let isModified: Bool
    let isTruncated: Bool
    let isLoadingFullValue: Bool

    let onSetNull: () -> Void
    let onSetDefault: () -> Void
    let onSetEmpty: () -> Void
    let onSetFunction: (String) -> Void

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var isSetPopoverPresented = false
    @State private var hexEditText = ""

    private var placeholderText: String {
        if hasMultipleValues {
            return String(localized: "Multiple values")
        } else if let original = originalValue {
            return original
        } else {
            return "NULL"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: modified indicator + field name + type badge
            HStack(spacing: 4) {
                if isModified {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }

                Text(columnName)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .lineLimit(1)

                Spacer()

                Text(columnTypeEnum.badgeLabel)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(Capsule())

                if isTruncated && !isLoadingFullValue {
                    Text("truncated")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            // Line 2: full-width editor with inline menu overlay
            typeAwareEditor
                .overlay(alignment: .topTrailing) {
                    fieldMenu
                        .opacity(isHovered ? 1 : 0)
                        .padding(.trailing, 4)
                }
        }
        .onHover { isHovered = $0 }
    }

    // MARK: - Type-Aware Editor

    @ViewBuilder
    private var typeAwareEditor: some View {
        if isLoadingFullValue {
            TextField("", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .disabled(true)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        } else if isTruncated {
            Text("Failed to load full value")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else if isPendingNull || isPendingDefault {
            TextField(isPendingNull ? "NULL" : "DEFAULT", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .disabled(true)
        } else if columnTypeEnum.isEnumType,
                  let values = columnTypeEnum.enumValues, !values.isEmpty {
            enumPicker(values: values)
        } else if columnTypeEnum.isSetType,
                  let values = columnTypeEnum.enumValues, !values.isEmpty {
            setPicker(values: values)
        } else if columnTypeEnum.isBooleanType {
            booleanPicker
        } else if BlobFormattingService.shared.requiresFormatting(columnType: columnTypeEnum) {
            blobHexEditor
        } else if isLongText || columnTypeEnum.isJsonType {
            multiLineEditor
        } else {
            singleLineEditor
        }
    }

    private var blobHexEditor: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Hex bytes", text: $hexEditText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny, design: .monospaced))
                .lineLimit(3...8)
                .focused($isFocused)
                .onAppear {
                    hexEditText = BlobFormattingService.shared.format(value, for: .edit) ?? ""
                }
                .onChange(of: value) {
                    if !isFocused {
                        hexEditText = BlobFormattingService.shared.format(value, for: .edit) ?? ""
                    }
                }
                .onChange(of: isFocused) {
                    if !isFocused {
                        commitHexEdit()
                    }
                }

            HStack(spacing: 4) {
                if let byteCount = value.data(using: .isoLatin1)?.count, byteCount > 0 {
                    Text("\(byteCount) bytes")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny))
                        .foregroundStyle(.tertiary)
                }

                if BlobFormattingService.shared.parseHex(hexEditText) == nil, !hexEditText.isEmpty {
                    Text("Invalid hex")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func commitHexEdit() {
        if let raw = BlobFormattingService.shared.parseHex(hexEditText) {
            value = raw
        } else {
            hexEditText = BlobFormattingService.shared.format(value, for: .edit) ?? ""
        }
    }

    private var booleanPicker: some View {
        dropdownField(label: normalizeBooleanValue(value) == "1" ? "true" : "false") {
            Button("true") { value = "1" }
            Button("false") { value = "0" }
        }
    }

    private func enumPicker(values: [String]) -> some View {
        let label = value.isEmpty ? (values.first ?? "") : value
        return dropdownField(label: label) {
            ForEach(values, id: \.self) { val in
                Button(val) { value = val }
            }
        }
    }

    private func setPicker(values: [String]) -> some View {
        let displayLabel = value.isEmpty ? String(localized: "No selection") : value
        return Button {
            isSetPopoverPresented = true
        } label: {
            Text(displayLabel)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
        .popover(isPresented: $isSetPopoverPresented) {
            SetPopoverContentView(
                allowedValues: values,
                initialSelections: parseSetSelections(from: value, allowed: values),
                onCommit: { result in
                    value = result ?? ""
                },
                onDismiss: {
                    isSetPopoverPresented = false
                }
            )
        }
    }

    private func parseSetSelections(from value: String, allowed: [String]) -> [String: Bool] {
        let selected = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        var dict: [String: Bool] = [:]
        for val in allowed {
            dict[val] = selected.contains(val)
        }
        return dict
    }

    private func dropdownField<Content: View>(
        label: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            Text(label)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
    }

    private var multiLineEditor: some View {
        TextField(placeholderText, text: $value, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .lineLimit(3...6)
            .focused($isFocused)
    }

    private var singleLineEditor: some View {
        TextField(placeholderText, text: $value)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .focused($isFocused)
    }

    // MARK: - Field Menu

    private var fieldMenu: some View {
        Menu {
            Button("Set NULL") {
                onSetNull()
            }

            Button("Set DEFAULT") {
                onSetDefault()
            }

            Button("Set EMPTY") {
                onSetEmpty()
            }

            Divider()

            if columnTypeEnum.isJsonType {
                Button("Pretty Print") {
                    if let formatted = value.prettyPrintedAsJson() {
                        value = formatted
                    }
                }
            }

            if BlobFormattingService.shared.requiresFormatting(columnType: columnTypeEnum) {
                Button("Copy as Hex") {
                    if let hex = BlobFormattingService.shared.format(value, for: .detail) {
                        ClipboardService.shared.writeText(hex)
                    }
                }
            }

            Button("Copy Value") {
                ClipboardService.shared.writeText(value)
            }

            Divider()

            Menu("SQL Functions") {
                Button("NOW()") { onSetFunction("NOW()") }
                Button("CURRENT_TIMESTAMP()") { onSetFunction("CURRENT_TIMESTAMP()") }
                Button("CURDATE()") { onSetFunction("CURDATE()") }
                Button("CURTIME()") { onSetFunction("CURTIME()") }
                Button("UTC_TIMESTAMP()") { onSetFunction("UTC_TIMESTAMP()") }
            }

            if isPendingNull || isPendingDefault {
                Divider()
                Button("Clear") {
                    value = originalValue ?? ""
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Helpers

    private func normalizeBooleanValue(_ val: String) -> String {
        let lower = val.lowercased()
        if lower == "true" || lower == "1" || lower == "t" || lower == "yes" {
            return "1"
        }
        return "0"
    }
}

/// Read-only field view using native macOS components
struct ReadOnlyFieldView: View {
    let columnName: String
    let columnTypeEnum: ColumnType
    let isLongText: Bool
    let value: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Line 1: field name + type badge
            HStack(spacing: 4) {
                Text(columnName)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .lineLimit(1)

                Spacer()

                Text(columnTypeEnum.badgeLabel)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }

            // Line 2: value in disabled native text field
            if let value {
                if BlobFormattingService.shared.requiresFormatting(columnType: columnTypeEnum) {
                    ScrollView {
                        Text(BlobFormattingService.shared.formatIfNeeded(value, columnType: columnTypeEnum, for: .detail))
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxHeight: 120)
                } else if isLongText {
                    Text(value)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, maxHeight: 80, alignment: .topLeading)
                } else {
                    TextField("", text: .constant(value))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        .disabled(true)
                }
            } else {
                TextField("NULL", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .disabled(true)
            }
        }
        .contextMenu {
            if let value {
                Button("Copy Value") {
                    ClipboardService.shared.writeText(value)
                }

                if BlobFormattingService.shared.requiresFormatting(columnType: columnTypeEnum) {
                    Button("Copy as Hex") {
                        if let hex = BlobFormattingService.shared.format(value, for: .detail) {
                            ClipboardService.shared.writeText(hex)
                        }
                    }
                }
            }
        }
    }
}
