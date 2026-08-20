//
//  FieldDetailView.swift
//  TablePro
//
//  Thin orchestrator for field detail display in the right sidebar.
//  Delegates to extracted editor views via FieldEditorResolver.
//

import SwiftUI

internal struct FieldDetailView: View {
    let context: FieldEditorContext
    let isPendingNull: Bool
    let isPendingDefault: Bool
    let isModified: Bool
    let databaseType: DatabaseType
    let onSetNull: () -> Void
    let onSetDefault: () -> Void
    let onSetEmpty: () -> Void
    let onSetFunction: (String) -> Void
    var isPrimaryKey: Bool = false
    var isForeignKey: Bool = false
    var onExpand: (() -> Void)?
    var onPopOut: ((String) -> Void)?

    @State private var isHovered = false

    private var offersNullAndDefault: Bool {
        !context.isReadOnly && context.allowsNullAndDefault
    }

    var body: some View {
        let kind = FieldEditorResolver.resolve(context: context)

        let isPickerField: Bool = {
            switch kind {
            case .boolean, .enumPicker, .setPicker: return true
            default: return false
            }
        }()
        let showsFieldMenu = offersNullAndDefault

        VStack(alignment: .leading, spacing: 4) {
            fieldHeader

            if isPickerField {
                resolvedEditor(for: kind)
            } else {
                PendingStateOverlay(
                    isPendingNull: isPendingNull,
                    isPendingDefault: isPendingDefault,
                    minHeight: editorMinHeight(for: kind)
                ) {
                    resolvedEditor(for: kind)
                }
                .overlay(alignment: .topTrailing) {
                    if showsFieldMenu && isHovered {
                        FieldMenuView(
                            value: context.value.wrappedValue,
                            columnType: context.columnType,
                            sqlFunctions: SQLFunctionProvider.functions(for: databaseType),
                            isPendingNull: isPendingNull,
                            isPendingDefault: isPendingDefault,
                            onSetNull: onSetNull,
                            onSetDefault: onSetDefault,
                            onSetEmpty: onSetEmpty,
                            onSetFunction: onSetFunction,
                            onClear: { context.value.wrappedValue = context.originalValue ?? "" }
                        )
                        .padding(.trailing, 4)
                    }
                }
            }
        }
        .labelsHidden()
        .onHover { isHovered = $0 }
        .contextMenu {
            if showsFieldMenu {
                FieldMenuContent(
                    value: context.value.wrappedValue,
                    columnType: context.columnType,
                    sqlFunctions: SQLFunctionProvider.functions(for: databaseType),
                    isPendingNull: isPendingNull,
                    isPendingDefault: isPendingDefault,
                    onSetNull: onSetNull,
                    onSetDefault: onSetDefault,
                    onSetEmpty: onSetEmpty,
                    onSetFunction: onSetFunction,
                    onClear: { context.value.wrappedValue = context.originalValue ?? "" }
                )
            }
        }
    }

    // MARK: - Header

    private var fieldHeader: some View {
        HStack(spacing: 4) {
            if isModified {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }

            if isPrimaryKey {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            } else if isForeignKey {
                Image(systemName: "arrow.right.arrow.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(context.columnName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            if context.showsTypeBadge {
                TypeBadge(context.columnType.badgeLabel)
            }
        }
        .textSelection(.enabled)
    }

    private func editorMinHeight(for kind: FieldEditorKind) -> CGFloat? {
        switch kind {
        case .json:
            return context.isReadOnly ? 60 : 80
        case .phpSerialized:
            return 80
        case .blobHex:
            return 60
        default:
            return nil
        }
    }

    // MARK: - Editor Dispatch

    private func resolvedEditor(for kind: FieldEditorKind) -> some View {
        editorContent(for: kind)
            .accessibilityLabel(context.columnName)
            .accessibilityValue(context.value.wrappedValue)
    }

    @ViewBuilder
    private func editorContent(for kind: FieldEditorKind) -> some View {
        switch kind {
        case .json:
            JsonEditorView(context: context, onExpand: onExpand, onPopOut: onPopOut)
        case .phpSerialized:
            PhpSerializedFieldView(context: context, onExpand: onExpand, onPopOut: onPopOut)
        case .blobHex:
            BlobHexEditorView(context: context)
        case .boolean:
            BooleanPickerView(
                context: context,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault,
                onSetNull: offersNullAndDefault ? onSetNull : nil,
                onSetDefault: offersNullAndDefault ? onSetDefault : nil
            )
        case .enumPicker(let values):
            EnumPickerView(
                context: context,
                values: values,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault,
                onSetNull: offersNullAndDefault ? onSetNull : nil,
                onSetDefault: offersNullAndDefault ? onSetDefault : nil
            )
        case .setPicker(let values):
            SetPickerView(
                context: context,
                values: values,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault,
                onSetNull: offersNullAndDefault ? onSetNull : nil,
                onSetDefault: offersNullAndDefault ? onSetDefault : nil
            )
        case .typePicker:
            TypePickerFieldView(context: context, databaseType: databaseType)
        case .schemaText:
            SchemaTextFieldView(context: context)
        case .multiLine:
            MultiLineEditorView(context: context)
        case .singleLine:
            SingleLineEditorView(context: context)
        }
    }
}
