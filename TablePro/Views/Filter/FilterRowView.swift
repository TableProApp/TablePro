//
//  FilterRowView.swift
//  TablePro
//
//  Single filter row view with native macOS styling.
//  Extracted from FilterPanelView for better maintainability.
//

import AppKit
import SwiftUI

/// Single filter row view with native macOS styling
struct FilterRowView: View {
    @Binding var filter: TableFilter
    let columns: [String]
    let isFocused: Bool
    let onDuplicate: () -> Void
    let onRemove: () -> Void
    let onApply: () -> Void
    let onFocus: () -> Void

    @State private var isHovered: Bool = false

    /// Display name for the column (handles raw SQL and empty)
    private var displayColumnName: String {
        if filter.columnName == TableFilter.rawSQLColumn {
            return String(localized: "Raw SQL")
        } else if filter.columnName.isEmpty {
            return String(localized: "Column")
        } else {
            return filter.columnName
        }
    }

    /// Dynamic background color based on state
    private var backgroundFillColor: Color {
        if isFocused {
            return Color(nsColor: .controlAccentColor).opacity(0.08)
        } else if isHovered {
            return Color(nsColor: .controlBackgroundColor)
        } else {
            return Color.clear
        }
    }

    /// Dynamic border color based on state
    private var borderColor: Color {
        if isFocused {
            return Color(nsColor: .controlAccentColor).opacity(0.3)
        } else if isHovered {
            return Color(nsColor: .separatorColor).opacity(0.5)
        } else {
            return Color.clear
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Checkbox for multi-select
            Toggle("", isOn: $filter.isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Select filter for \(displayColumnName)"))

            // Column dropdown - native Menu style
            columnMenu
                .frame(width: 120)

            // Operator dropdown (hidden for raw SQL)
            if !filter.isRawSQL {
                operatorMenu
                    .frame(width: 110)
            }

            // Value field(s)
            valueFields

            Spacer(minLength: 0)

            // Action buttons
            actionButtons
        }
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xs)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    // MARK: - Column Menu

    private var columnMenu: some View {
        Menu {
            Button(action: { filter.columnName = TableFilter.rawSQLColumn }) {
                if filter.columnName == TableFilter.rawSQLColumn {
                    Label("Raw SQL", systemImage: "checkmark")
                } else {
                    Text("Raw SQL")
                }
            }

            if !columns.isEmpty {
                Divider()
                ForEach(columns, id: \.self) { column in
                    Button(action: { filter.columnName = column }) {
                        if filter.columnName == column {
                            Label(column, systemImage: "checkmark")
                        } else {
                            Text(column)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayColumnName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(String(localized: "Filter column: \(displayColumnName)"))
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
    }

    // MARK: - Operator Menu

    private var operatorMenu: some View {
        Menu {
            ForEach(FilterOperator.allCases) { op in
                Button(action: { filter.filterOperator = op }) {
                    if filter.filterOperator == op {
                        Label(op.displayName, systemImage: "checkmark")
                    } else {
                        Text(op.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(filter.filterOperator.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(
            String(localized: "Filter operator: \(filter.filterOperator.displayName)")
        )
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
    }

    // MARK: - Value Fields

    @ViewBuilder
    private var valueFields: some View {
        if filter.isRawSQL {
            // Raw SQL input
            TextField("WHERE clause...", text: Binding(
                get: { filter.rawSQL ?? "" },
                set: { filter.rawSQL = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .onSubmit { onApply() }
            .simultaneousGesture(TapGesture().onEnded { onFocus() })
        } else if filter.filterOperator.requiresValue {
            // Standard value input
            TextField("Value", text: $filter.value)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .frame(minWidth: 80)
                .onSubmit { onApply() }
                .simultaneousGesture(TapGesture().onEnded { onFocus() })

            // Second value for BETWEEN
            if filter.filterOperator.requiresSecondValue {
                Text("and")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField("Value", text: Binding(
                    get: { filter.secondValue ?? "" },
                    set: { filter.secondValue = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
                .frame(minWidth: 80)
                .onSubmit { onApply() }
                .simultaneousGesture(TapGesture().onEnded { onFocus() })
            }
        } else {
            // No value needed (IS NULL, etc.) - show indicator
            Text("—")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(minWidth: 80, alignment: .leading)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Apply single filter
            Button(action: onApply) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(filter.isValid ? Color(nsColor: .systemGreen) : Color.secondary)
            .disabled(!filter.isValid)
            .accessibilityLabel(String(localized: "Apply this filter"))
            .help("Apply This Filter")

            // Duplicate
            Button(action: onDuplicate) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "Duplicate filter"))
            .help("Duplicate Filter")

            // Remove
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(String(localized: "Remove filter"))
            .help("Remove Filter")
        }
    }
}
