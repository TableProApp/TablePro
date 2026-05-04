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
    let isTruncated: Bool
    let isLoadingFullValue: Bool
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

    var body: some View {
        let kind = FieldEditorResolver.resolve(
            for: context.columnType,
            isLongText: context.isLongText,
            originalValue: context.originalValue
        )

        let isPickerField: Bool = {
            switch kind {
            case .boolean, .enumPicker, .setPicker: return true
            default: return false
            }
        }()

        VStack(alignment: .leading, spacing: 4) {
            fieldHeader

            if isPickerField {
                resolvedEditor(for: kind)
            } else {
                PendingStateOverlay(
                    isPendingNull: isPendingNull,
                    isPendingDefault: isPendingDefault,
                    isLoadingFullValue: isLoadingFullValue,
                    isTruncated: isTruncated,
                    minHeight: editorMinHeight(for: kind)
                ) {
                    resolvedEditor(for: kind)
                }
                .overlay(alignment: .topTrailing) {
                    if !context.isReadOnly && isHovered {
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
                    .foregroundStyle(Color(nsColor: .systemYellow))
            } else if isForeignKey {
                Image(systemName: "arrow.right.arrow.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(context.columnName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            Text(context.columnType.badgeLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary)
                .clipShape(Capsule())

            if isTruncated && !isLoadingFullValue {
                Text("truncated")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .systemOrange).opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }

    private func editorMinHeight(for kind: FieldEditorKind) -> CGFloat? {
        switch kind {
        case .json:
            return context.isReadOnly ? 60 : 80
        case .blobHex:
            return 60
        default:
            return nil
        }
    }

    // MARK: - Editor Dispatch

    @ViewBuilder
    private func resolvedEditor(for kind: FieldEditorKind) -> some View {
        switch kind {
        case .json:
            JsonEditorView(context: context, onExpand: onExpand, onPopOut: onPopOut)
        case .blobHex:
            BlobHexEditorView(context: context)
        case .boolean:
            BooleanPickerView(
                context: context,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault,
                onSetNull: context.isReadOnly ? nil : onSetNull,
                onSetDefault: context.isReadOnly ? nil : onSetDefault
            )
        case .enumPicker(let values):
            EnumPickerView(
                context: context,
                values: values,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault,
                onSetNull: context.isReadOnly ? nil : onSetNull,
                onSetDefault: context.isReadOnly ? nil : onSetDefault
            )
        case .setPicker(let values):
            SetPickerView(
                context: context,
                values: values,
                isPendingNull: isPendingNull,
                isPendingDefault: isPendingDefault,
                onSetNull: context.isReadOnly ? nil : onSetNull,
                onSetDefault: context.isReadOnly ? nil : onSetDefault
            )
        case .multiLine:
            MultiLineEditorView(context: context)
        case .singleLine:
            SingleLineEditorView(context: context)
        }
    }
}
