//
//  MaintenanceSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Confirms a maintenance operation and shows the statements that will run.
///
/// The preview is the driver's own SQL, handed in as a closure, and the Execute button sends the same
/// option values back through the same builder. It used to write its own copy of the statement and
/// disagree with it: `REINDEX orders`, which is not valid SQL, where `REINDEX TABLE "orders"` ran.
/// The option controls come from the operation for the same reason, rather than from a switch gated
/// on two engine names.
struct MaintenanceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let operation: PluginMaintenanceOperation
    let tableName: String?
    let databaseName: String?
    /// Statements for the given option values. Synchronous and pure, so calling it for every toggle
    /// while `body` runs costs an array of strings.
    let preview: ([String: String]) -> [String]
    let onExecute: ([String: String]) -> Void

    @State private var values: [String: String]

    init(
        operation: PluginMaintenanceOperation,
        tableName: String?,
        databaseName: String?,
        preview: @escaping ([String: String]) -> [String],
        onExecute: @escaping ([String: String]) -> Void
    ) {
        self.operation = operation
        self.tableName = tableName
        self.databaseName = databaseName
        self.preview = preview
        self.onExecute = onExecute
        _values = State(initialValue: operation.defaultOptionValues)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            if !operation.options.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(operation.options, id: \.key) { option in
                        optionControl(option)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "SQL Preview"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sqlPreview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Divider()

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Execute")) {
                    onExecute(values)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(sqlPreview.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.name)
                    .font(.headline)
                if let subject {
                    Text(subject)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    /// What the statement acts on. An operation that names no object reads as the database it runs
    /// against, rather than as the table the row it was reached from happened to be.
    private var subject: String? {
        operation.target(tableName)?.nilIfEmpty ?? databaseName?.nilIfEmpty
    }

    @ViewBuilder
    private func optionControl(_ option: PluginMaintenanceOption) -> some View {
        if let choices = option.choices {
            Picker(option.label, selection: binding(for: option)) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        } else {
            Toggle(option.label, isOn: toggleBinding(for: option))
        }
    }

    private func binding(for option: PluginMaintenanceOption) -> Binding<String> {
        Binding(
            get: { values[option.key] ?? option.defaultValue },
            set: { values[option.key] = $0 }
        )
    }

    private func toggleBinding(for option: PluginMaintenanceOption) -> Binding<Bool> {
        Binding(
            get: { (values[option.key] ?? option.defaultValue) == "true" },
            set: { values[option.key] = $0 ? "true" : "false" }
        )
    }

    private var sqlPreview: String {
        preview(values).joined(separator: ";\n")
    }
}
