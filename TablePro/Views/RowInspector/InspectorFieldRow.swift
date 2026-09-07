//
//  InspectorFieldRow.swift
//  TablePro
//

import SwiftUI

/// One field of the inspected row.
///
/// The row owns its own chrome and its own value menu. The menu used to be rendered only inside
/// `.overlay { if isHovered { ... } }`, so the one route to Set NULL, Set DEFAULT and the SQL
/// functions was to put a pointer on the field: invisible to the keyboard, invisible to VoiceOver
/// and invisible to anyone who does not happen to hover. It is drawn unconditionally now, which is
/// what Postico does and what a control that is the only way to reach a command has to do.
internal struct InspectorFieldRow: View {
    internal let context: FieldEditorContext
    internal let layout: InspectorFieldLayout
    internal let kind: FieldEditorKind
    internal let isModified: Bool
    internal let isPrimaryKey: Bool
    internal let isForeignKey: Bool
    internal let databaseType: DatabaseType
    internal let isExpanded: Bool
    internal let onSetNull: () -> Void
    internal let onSetDefault: () -> Void
    internal let onSetEmpty: () -> Void
    internal let onSetFunction: (String) -> Void
    internal var onToggleExpand: (() -> Void)?
    internal var onPopOut: ((String) -> Void)?

    @FocusState.Binding internal var focusedField: UUID?
    internal let fieldID: UUID

    var body: some View {
        Group {
            switch layout {
            case .inline: inlineRow
            case .stacked: stackedRow
            }
        }
        .contentShape(Rectangle())
        .contextMenu { menuContent }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Layouts

    /// A schema row: the label in a fixed trailing-aligned lane, the editor filling what is left.
    /// The lane is a constant because the label vocabulary is closed and authored; its widest member
    /// renders at 66.4pt, so 96 carries every one of them with room for a longer translation.
    private var inlineRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(spacing: 3) {
                statusGlyphs
                fieldLabel
            }
            .frame(width: Self.schemaLabelLaneWidth, alignment: .trailing)
            editor
                .frame(maxWidth: .infinity, alignment: .leading)
            modifiedGlyph
            valueMenu
        }
        .padding(.vertical, 3)
    }

    /// A data row: name and type on their own line, the value at full width beneath. Every value in
    /// the pane then starts at the same x and gets the whole content width, against the 24 to 31pt a
    /// long column name used to leave it.
    private var stackedRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                statusGlyphs
                fieldLabel
                Spacer(minLength: 4)
                modifiedGlyph
                if context.showsTypeBadge {
                    TypeBadge(context.columnType.badgeLabel)
                }
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
        .padding(.vertical, 2)
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
    /// recording an edit cannot shift the name it belongs to.
    @ViewBuilder
    private var modifiedGlyph: some View {
        if isModified {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        var parts = [context.columnName]
        if isPrimaryKey { parts.append(String(localized: "Primary key")) }
        if isForeignKey { parts.append(String(localized: "Foreign key")) }
        if context.showsTypeBadge { parts.append(context.columnType.badgeLabel) }
        if isModified { parts.append(String(localized: "Modified")) }
        return parts.joined(separator: ", ")
    }

    // MARK: - Value menu

    /// Always drawn, never hover-gated.
    private var valueMenu: some View {
        Menu {
            menuContent
        } label: {
            Label(String(localized: "Value Options"), systemImage: "chevron.down")
        }
        .labelStyle(.iconOnly)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(minWidth: 12)
        .help(String(localized: "Value Options"))
        .accessibilityIdentifier("inspector-value-menu")
    }

    private var menuContent: some View {
        FieldMenuContent(
            value: context.copyableValue,
            columnType: context.columnType,
            sqlFunctions: SQLFunctionProvider.functions(for: databaseType),
            canMutate: context.canMutate,
            isPendingNull: context.valueState == .pendingNull,
            isPendingDefault: context.valueState == .pendingDefault,
            onSetNull: onSetNull,
            onSetDefault: onSetDefault,
            onSetEmpty: onSetEmpty,
            onSetFunction: onSetFunction,
            onClear: { context.value.wrappedValue = context.originalValue ?? "" }
        )
    }

    // MARK: - Editor

    private var editor: some View {
        FieldEditorContent(
            context: context,
            kind: kind,
            databaseType: databaseType,
            onSetNull: context.canMutate ? onSetNull : nil,
            onSetDefault: context.canMutate ? onSetDefault : nil,
            onPopOut: onPopOut,
            isExpanded: isExpanded
        )
            .font(Self.valueFont(for: kind))
            .focused($focusedField, equals: fieldID)
            .accessibilityValue(context.valueState.placeholder ?? context.value.wrappedValue)
    }

    /// One exhaustive switch, so a new editor kind has to be classified rather than inheriting the
    /// arm that happened to be written first. Two `default`-armed switches over this enum are what
    /// let `.typePicker` escape the value-font domain and render a structure row's Name and Type
    /// fields in two different fonts side by side.
    ///
    /// The three structured editors opt out because each carries a toolbar and its own placeholders
    /// alongside the value, and each presents the same way in a pop-out window where there is no
    /// ambient font to inherit; they name the value font on their own value text instead.
    private static func valueFont(for kind: FieldEditorKind) -> Font? {
        switch kind {
        case .json, .phpSerialized, .image:
            return nil
        case .blobHex, .boolean, .enumPicker, .setPicker, .typePicker, .schemaText, .multiLine, .singleLine:
            return ThemeEngine.shared.valueFontSwiftUI
        }
    }


    /// The lane a schema row's label sits in. The vocabulary is closed and authored, and its widest
    /// member, "Ref Columns", renders at 66.4pt in `.subheadline`, so this carries every label with
    /// 45% left over for a longer translation. A label that still overruns truncates in the middle
    /// and keeps its tooltip rather than taking the width from its own value.
    ///
    /// It is a constant, not a measurement. A lane derived from the rows on screen would change
    /// width as the user scrolls, because a `PreferenceKey` max-reduce inside a `List` only ever
    /// sees the realized rows.
    private static let schemaLabelLaneWidth: CGFloat = 96
}
