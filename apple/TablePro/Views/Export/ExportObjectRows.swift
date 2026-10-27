//
//  ExportObjectRows.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// How each object kind names and draws itself in the export tree. One table rather than a switch
/// per call site, so a kind added later cannot pick up a different icon in one of them.
internal enum ExportObjectKindPresentation {
    internal static func groupTitle(for kind: PluginExportObjectKind) -> String {
        switch kind {
        case .table: return String(localized: "Tables")
        case .view: return String(localized: "Views")
        case .materializedView: return String(localized: "Materialized Views")
        case .foreignTable: return String(localized: "Foreign Tables")
        case .sequence: return String(localized: "Sequences")
        case .userType: return String(localized: "Types")
        case .routine: return String(localized: "Routines")
        case .trigger: return String(localized: "Triggers")
        case .event: return String(localized: "Events")
        case .grant: return String(localized: "Privileges")
        @unknown default: return String(localized: "Objects")
        }
    }

    internal static func iconName(for kind: PluginExportObjectKind) -> String {
        switch kind {
        case .table, .foreignTable: return "tablecells"
        case .view, .materializedView: return "eye"
        case .sequence: return "number"
        case .userType: return "curlybraces"
        case .routine: return "function"
        case .trigger: return "bolt"
        case .event: return "clock"
        case .grant: return "key"
        @unknown default: return "shippingbox"
        }
    }

    internal static func checkboxValue(for state: TristateCheckbox.State) -> String {
        switch state {
        case .checked: String(localized: "Selected")
        case .unchecked: String(localized: "Not selected")
        case .mixed: String(localized: "Partly selected")
        }
    }

    internal static func iconColor(for kind: PluginExportObjectKind) -> Color {
        switch kind {
        case .table, .foreignTable: return .gray
        case .view, .materializedView: return .purple
        case .sequence: return .teal
        case .userType: return .orange
        case .routine: return .indigo
        case .trigger: return .pink
        case .event: return .brown
        case .grant: return .yellow
        @unknown default: return .secondary
        }
    }
}

/// A database row or a kind-group row: a tri-state checkbox that selects everything beneath it.
internal struct ExportTreeContainerRow: View {
    internal let title: String
    internal let iconName: String
    internal let iconColor: Color
    internal let state: TristateCheckbox.State
    internal let toggle: () -> Void

    internal var body: some View {
        HStack(spacing: 4) {
            TristateCheckbox(
                state: state,
                accessibilityLabel: title,
                accessibilityValue: ExportObjectKindPresentation.checkboxValue(for: state),
                action: toggle
            )
            .frame(width: 18)

            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.body)
                .accessibilityHidden(true)

            Text(title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }
}

// The checkbox only includes or excludes the object; what it writes is in the option columns.
internal struct ExportTreeObjectRow: View {
    internal let object: ExportObjectItem
    internal let offersRowScope: Bool
    internal let toggle: () -> Void
    internal let setRowScope: (PluginExportRowScope) -> Void
    internal let loadColumns: () async -> [String]

    @State private var isEditingScope = false
    @State private var editableScope: PluginExportRowScope = .unrestricted
    @State private var availableColumns: [String] = []

    internal var body: some View {
        HStack(spacing: 4) {
            Toggle(object.name, isOn: Binding(get: { object.isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)

            Image(systemName: ExportObjectKindPresentation.iconName(for: object.kind))
                .foregroundStyle(ExportObjectKindPresentation.iconColor(for: object.kind))
                .font(.body)
                .accessibilityHidden(true)

            Text(object.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            if let subtitle = object.subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if offersRowScope {
                rowScopeButton
            }
        }
    }

    /// Filled when the object is narrowed, so a tree of forty tables says at a glance which ones
    /// will not export whole.
    private var rowScopeButton: some View {
        Button {
            editableScope = object.rowScope
            isEditingScope = true
        } label: {
            Image(systemName: object.rowScope.isUnrestricted
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(object.rowScope.isUnrestricted ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "Row scope"))
        .accessibilityValue(object.rowScope.isUnrestricted
            ? String(localized: "Every row and column")
            : object.rowScope.summary)
        .help(object.rowScope.isUnrestricted
            ? String(localized: "Narrow the rows and columns to export")
            : object.rowScope.summary)
        .popover(isPresented: $isEditingScope, arrowEdge: .bottom) {
            ExportRowScopeEditor(
                objectName: object.name,
                availableColumns: availableColumns,
                scope: Binding(get: { editableScope }, set: { editableScope = $0; setRowScope($0) }),
                dismiss: { isEditingScope = false }
            )
            .task {
                guard availableColumns.isEmpty else { return }
                availableColumns = await loadColumns()
            }
        }
    }
}
