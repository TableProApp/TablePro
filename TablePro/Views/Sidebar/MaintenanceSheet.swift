//
//  MaintenanceSheet.swift
//  TablePro
//
//  Confirmation sheet for database maintenance operations
//  (VACUUM, ANALYZE, OPTIMIZE, REINDEX, etc.)
//

import SwiftUI

struct MaintenanceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let operation: String
    let tableName: String
    let databaseType: DatabaseType
    let onExecute: (String, String, [String: String]) -> Void

    @State private var fullVacuum = false
    @State private var analyzeAfterVacuum = false
    @State private var verbose = false
    @State private var checkMode = "MEDIUM"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation)
                        .font(.headline)
                    Text(tableName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Operation-specific options
            operationOptions

            // SQL preview
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "SQL Preview"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sqlPreview)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Divider()

            // Buttons
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Execute")) {
                    onExecute(operation, tableName, buildOptions())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Options

    @ViewBuilder
    private var operationOptions: some View {
        switch operation {
        case "VACUUM" where databaseType == .postgresql || databaseType == .redshift:
            Toggle(String(localized: "FULL (rewrites entire table, blocks access)"), isOn: $fullVacuum)
            Toggle(String(localized: "ANALYZE (update statistics after vacuum)"), isOn: $analyzeAfterVacuum)
            Toggle(String(localized: "VERBOSE (print progress)"), isOn: $verbose)
        case "CHECK TABLE":
            Picker(String(localized: "Check mode:"), selection: $checkMode) {
                Text("QUICK").tag("QUICK")
                Text("FAST").tag("FAST")
                Text("MEDIUM").tag("MEDIUM")
                Text("EXTENDED").tag("EXTENDED")
                Text("CHANGED").tag("CHANGED")
            }
            .pickerStyle(.menu)
            .frame(width: 200)
        default:
            EmptyView()
        }
    }

    // MARK: - SQL Preview

    private var sqlPreview: String {
        let options = buildOptions()
        switch operation {
        case "VACUUM" where databaseType == .postgresql || databaseType == .redshift:
            var opts: [String] = []
            if options["full"] == "true" { opts.append("FULL") }
            if options["analyze"] == "true" { opts.append("ANALYZE") }
            if options["verbose"] == "true" { opts.append("VERBOSE") }
            let optClause = opts.isEmpty ? "" : "(\(opts.joined(separator: ", "))) "
            return "VACUUM \(optClause)\(tableName)"
        case "CHECK TABLE":
            return "CHECK TABLE \(tableName) \(checkMode)"
        default:
            return "\(operation) \(tableName)"
        }
    }

    private func buildOptions() -> [String: String] {
        var options: [String: String] = [:]
        if fullVacuum { options["full"] = "true" }
        if analyzeAfterVacuum { options["analyze"] = "true" }
        if verbose { options["verbose"] = "true" }
        if operation == "CHECK TABLE" { options["mode"] = checkMode }
        return options
    }
}
