//
//  FieldMenuContent.swift
//  TablePro
//

import SwiftUI

/// The field actions (Set NULL/DEFAULT/EMPTY, Generate UUID, copy, SQL functions). Shared by the row's own pull
/// down and its context menu so both stay in sync.
///
/// A read-only field keeps the copy actions and loses the mutating ones. Hiding the whole menu
/// left a value that is neither selectable nor copyable. Each Set action is one `SetValueOptions` offers for
/// the column, so the inspector cannot offer NULL on a NOT NULL column the grid refuses it on.
internal struct FieldMenuContent: View {
    let value: String
    let columnType: ColumnType
    let commands: [SetValueCommand]
    let canMutate: Bool
    let isPendingNull: Bool
    let isPendingDefault: Bool
    var isPendingRemoval = false
    var isPendingExpression = false
    let onSetValue: (SetValueCommand) -> Void
    /// Offered only on an engine that tells a missing field from NULL, and only while the field is
    /// there to remove.
    var onRemoveField: (() -> Void)?
    let onClear: () -> Void

    var body: some View {
        if canMutate, hasSetActions {
            if commands.contains(.null) {
                Button("Set NULL") { onSetValue(.null) }
            }
            if commands.contains(.defaultValue) {
                Button("Set DEFAULT") { onSetValue(.defaultValue) }
            }
            if commands.contains(.empty) {
                Button("Set EMPTY") { onSetValue(.empty) }
            }
            ForEach(uuidCommands, id: \.self) { command in
                Button(SetValueOptions.title(for: command)) { onSetValue(command) }
            }
            if let onRemoveField {
                Button("Remove Field") { onRemoveField() }
            }

            Divider()
        }

        if columnType.isJsonType {
            Button("Pretty Print") {
                if let formatted = value.prettyPrintedAsJson() {
                    ClipboardService.shared.writeText(formatted)
                }
            }
        }

        if BlobFormattingService.shared.requiresFormatting(columnType: columnType) {
            Button("Copy as Hex") {
                if let hex = BlobFormattingService.shared.format(value, for: .detail) {
                    ClipboardService.shared.writeText(hex)
                }
            }
        }

        Button("Copy Value") {
            ClipboardService.shared.writeText(value)
        }

        if canMutate {
            if !expressionCommands.isEmpty {
                Divider()

                Menu("SQL Functions") {
                    ForEach(expressionCommands, id: \.self) { command in
                        Button(SetValueOptions.title(for: command)) { onSetValue(command) }
                    }
                }
            }

            if isPendingNull || isPendingDefault || isPendingRemoval || isPendingExpression {
                Divider()
                Button("Clear") { onClear() }
            }
        }
    }

    private var hasSetActions: Bool {
        onRemoveField != nil || commands.contains { !Self.isExpression($0) }
    }

    private var uuidCommands: [SetValueCommand] {
        commands.filter { command in
            if case .uuid = command { return true }
            return false
        }
    }

    private var expressionCommands: [SetValueCommand] {
        commands.filter(Self.isExpression)
    }

    private static func isExpression(_ command: SetValueCommand) -> Bool {
        if case .expression = command { return true }
        return false
    }
}
