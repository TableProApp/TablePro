//
//  FieldMenuContent.swift
//  TablePro
//

import SwiftUI

/// The field actions (Set NULL/DEFAULT/EMPTY, copy, SQL functions). Shared by the row's own pull
/// down and its context menu so both stay in sync.
///
/// A read-only field keeps the copy actions and loses the mutating ones. Hiding the whole menu
/// left a value that is neither selectable nor copyable.
internal struct FieldMenuContent: View {
    let value: String
    let columnType: ColumnType
    let sqlFunctions: [SQLFunctionProvider.SQLFunction]
    let canMutate: Bool
    let isPendingNull: Bool
    let isPendingDefault: Bool
    let onSetNull: () -> Void
    let onSetDefault: () -> Void
    let onSetEmpty: () -> Void
    let onSetFunction: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        if canMutate {
            Button("Set NULL") { onSetNull() }
            Button("Set DEFAULT") { onSetDefault() }
            Button("Set EMPTY") { onSetEmpty() }

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
            Divider()

            Menu("SQL Functions") {
                ForEach(sqlFunctions, id: \.expression) { function in
                    Button(function.label) { onSetFunction(function.expression) }
                }
            }

            if isPendingNull || isPendingDefault {
                Divider()
                Button("Clear") { onClear() }
            }
        }
    }
}
