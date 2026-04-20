//
//  FieldMenuView.swift
//  TablePro
//

import SwiftUI

internal struct FieldMenuView: View {
    let value: String
    let columnType: ColumnType
    let sqlFunctions: [SQLFunctionProvider.SQLFunction]
    let isPendingNull: Bool
    let isPendingDefault: Bool
    let onSetNull: () -> Void
    let onSetDefault: () -> Void
    let onSetEmpty: () -> Void
    let onSetFunction: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        Menu {
            Button("Set NULL") { onSetNull() }
            Button("Set DEFAULT") { onSetDefault() }
            Button("Set EMPTY") { onSetEmpty() }

            Divider()

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
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
