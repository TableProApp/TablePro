//
//  InspectorFieldRow.swift
//  TablePro
//

import SwiftUI

/// One field of the inspected row. Its value menu is always drawn: it is the only route to Set
/// NULL, Set DEFAULT, Generate UUID and the SQL functions, and a hover-gated one hid them from the keyboard.
internal struct InspectorFieldRow: View {
    @ObservedObject private var themeEngine = ThemeEngine.shared
    internal let context: FieldEditorContext
    internal let kind: FieldEditorKind
    internal let isModified: Bool
    internal let isPrimaryKey: Bool
    internal let isForeignKey: Bool
    internal let isExpanded: Bool
    internal let resizedHeight: Binding<Double?>
    internal let commands: [SetValueCommand]
    internal var isPendingExpression = false
    internal let onSetValue: (SetValueCommand) -> Void
    internal var onRemoveField: (() -> Void)?
    internal var onToggleExpand: (() -> Void)?
    internal var onPopOut: ((String) -> Void)?
    internal var onTabStopChange: ((Bool) -> Void)?

    @FocusState.Binding internal var focusedField: UUID?
    internal let fieldID: UUID

    var body: some View {
        row
            .contentShape(Rectangle())
            .contextMenu { menuContent }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Layout

    // Always stacked: a column name has no length bound, so a label lane beside the value truncated both.
    private var row: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.labelToValue) {
            HStack(spacing: 4) {
                statusGlyphs
                fieldLabel
                Spacer(minLength: 4)
                modifiedGlyph
                TypeBadge(context.columnType.badgeLabel)
                if let onToggleExpand {
                    Button(
                        isExpanded ? String(localized: "Collapse") : String(localized: "Expand"),
                        systemImage: isExpanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        action: onToggleExpand
                    )
                    .labelStyle(.iconOnly)
                    .font(.caption2)
                    .buttonStyle(.borderless)
                    .help(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
                }
                valueMenu
            }
            editor
        }
        .padding(.vertical, InspectorMetrics.betweenFields / 2)
    }

    /// Carries the full name as a tooltip, which is what the HIG asks of a label it had to clip:
    /// "consider using an expansion tooltip to show the full version of clipped or truncated text".
    private var fieldLabel: some View {
        Text(context.columnName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(context.columnName)
    }

    // MARK: - Header pieces

    /// Drawn without accessibility of their own; the row's own label carries what they mean, so a
    /// reader is told which field is the primary key and which holds an unsaved edit. They were
    /// bare `Image` and `Circle` decoration before and said nothing at all.
    ///
    /// A row with neither takes no width for them, so its name sits at the same leading edge as the
    /// value beneath it. Reserving the space on every row instead indented every name past its own
    /// value by 18pt, which is the misalignment this layout exists to remove.
    @ViewBuilder
    private var statusGlyphs: some View {
        if isPrimaryKey {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
                .accessibilityHidden(true)
        } else if isForeignKey {
            Image(systemName: "arrow.up.forward")
                .foregroundStyle(.secondary)
                .font(.caption2)
                .accessibilityHidden(true)
        }
    }

    /// The unsaved-edit marker sits at the trailing end rather than in front of the name, so
    /// recording an edit cannot shift the name it belongs to. It is the glyph the filter bar's
    /// Show edited fields only toggle draws, so the two read as one idea, and not a coloured dot.
    @ViewBuilder
    private var modifiedGlyph: some View {
        if isModified {
            Image(systemName: "pencil.line")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        var parts = [context.columnName]
        if isPrimaryKey { parts.append(String(localized: "Primary key")) }
        if isForeignKey { parts.append(String(localized: "Foreign key")) }
        parts.append(context.columnType.badgeLabel)
        if isModified { parts.append(String(localized: "Modified")) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Value menu

    /// Always drawn, never hover-gated.
    ///
    /// The button's own disclosure chevron is the whole control. A chevron supplied as the label
    /// would be its icon and would render beside that one, which is why the hand-drawn version had
    /// to hide the real indicator to look right at all. The `Label` carries a title with no icon so
    /// the control still has a name: `.accessibilityLabel` on a `Menu` does not add one, it
    /// replaces whatever the label was providing with nothing.
    private var valueMenu: some View {
        Menu {
            menuContent
        } label: {
            Label { Text("Value Options") } icon: { EmptyView() }
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .help(String(localized: "Value Options"))
        .accessibilityIdentifier("inspector-value-menu")
    }

    private var menuContent: some View {
        FieldMenuContent(
            value: context.copyableValue,
            columnType: context.columnType,
            commands: commands,
            canMutate: context.canMutate,
            isPendingNull: context.valueState == .pendingNull,
            isPendingDefault: context.valueState == .pendingDefault,
            isPendingRemoval: context.valueState == .pendingRemoval,
            isPendingExpression: isPendingExpression,
            onSetValue: onSetValue,
            onRemoveField: context.valueState == .absent || context.valueState == .pendingRemoval
                ? nil : onRemoveField,
            onClear: { context.value.wrappedValue = context.originalValue ?? "" }
        )
    }

    // MARK: - Editor

    private var editor: some View {
        FieldEditorContent(
            context: context,
            kind: kind,
            resizedHeight: resizedHeight,
            onSetNull: context.canMutate && commands.contains(.null) ? { onSetValue(.null) } : nil,
            onSetDefault: context.canMutate && commands.contains(.defaultValue) ? { onSetValue(.defaultValue) } : nil,
            onPopOut: onPopOut,
            isExpanded: isExpanded,
            onTabStopChange: onTabStopChange
        )
            .font(Self.valueFont(for: kind))
            .focused($focusedField, equals: fieldID)
            .accessibilityValue(context.valueState.placeholder ?? context.value.wrappedValue)
    }

    /// Exhaustive, so a new kind is classified instead of inheriting an arm. The structured editors
    /// opt out: each carries a toolbar beside the value and names the value font on its own text.
    private static func valueFont(for kind: FieldEditorKind) -> Font? {
        switch kind {
        case .json, .phpSerialized, .binaryValue, .image:
            return nil
        case .geometry:
            return nil
        case .blobHex, .boolean, .enumPicker, .setPicker, .arrayElements, .vector, .multiLine, .singleLine:
            return ThemeEngine.shared.valueFontSwiftUI
        }
    }
}
