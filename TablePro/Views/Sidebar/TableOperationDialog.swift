//
//  TableOperationDialog.swift
//  TablePro
//
//  Confirmation dialog for table delete/truncate operations.
//  Provides options for foreign key constraint handling and cascade operations.
//

import os
import SwiftUI

/// Confirmation dialog for table delete/truncate operations
struct TableOperationDialog: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TableOperationDialog")

    // MARK: - Properties

    @Binding var isPresented: Bool
    let tableName: String
    let tableCount: Int
    let operationType: TableOperationType
    let databaseType: DatabaseType
    let onConfirm: (TableOperationOptions) -> Void

    // MARK: - State

    @State private var ignoreForeignKeys = false
    @State private var cascade = false

    // MARK: - Computed Properties

    private var title: String {
        switch operationType {
        case .drop:
            return tableCount > 1
                ? String(format: String(localized: "Drop %d tables"), tableCount)
                : String(format: String(localized: "Drop table '%@'"), tableName)
        case .truncate:
            return tableCount > 1
                ? String(format: String(localized: "Truncate %d tables"), tableCount)
                : String(format: String(localized: "Truncate table '%@'"), tableName)
        }
    }

    private var cascadeSupported: Bool {
        PluginManager.shared.supportsCascadeDrop(for: databaseType)
    }

    private var isMultipleTables: Bool {
        tableCount > 1
    }

    private var cascadeDescription: String {
        switch operationType {
        case .drop:
            return String(localized: "Drop all tables that depend on this table")
        case .truncate:
            if !cascadeSupported {
                return String(localized: "Not supported for TRUNCATE with this database")
            }
            return String(localized: "Truncate all tables linked by foreign keys")
        }
    }

    private var cascadeDisabled: Bool {
        if operationType == .truncate && !cascadeSupported {
            return true
        }
        return !cascadeSupported
    }

    private var ignoreFKDisabled: Bool {
        !PluginManager.shared.supportsForeignKeyDisable(for: databaseType)
    }

    private var ignoreFKDescription: String? {
        if !PluginManager.shared.supportsForeignKeyDisable(for: databaseType) {
            if cascadeSupported {
                return String(localized: "Not supported for this database. Use CASCADE instead.")
            }
            return String(localized: "Not supported for this database.")
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text(title)
                .font(.body.weight(.semibold))
                .padding(.vertical, 16)
                .padding(.horizontal, 20)

            Divider()

            // Options
            VStack(alignment: .leading, spacing: 16) {
                // Note for multiple tables
                if isMultipleTables {
                    Text("Same options will be applied to all selected tables.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Ignore foreign key checks
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $ignoreForeignKeys) {
                        Text("Ignore foreign key checks")
                            .font(.body)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(ignoreFKDisabled)

                    if let description = ignoreFKDescription {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }
                }
                .opacity(ignoreFKDisabled ? 0.6 : 1.0)

                // Cascade option
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $cascade) {
                        Text("Cascade")
                            .font(.body)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(cascadeDisabled)

                    Text(cascadeDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
                .opacity(cascadeDisabled ? 0.6 : 1.0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    isPresented = false
                }

                Spacer()

                Button("OK") {
                    confirmAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            isPresented = false
        }
        .onAppear {
            // Reset state when dialog opens
            ignoreForeignKeys = false
            cascade = false
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private func confirmAndDismiss() {
        // Values are already reset when their toggles become disabled,
        // so we can pass them directly without override checks
        let options = TableOperationOptions(
            ignoreForeignKeys: ignoreForeignKeys,
            cascade: cascade
        )
        onConfirm(options)
        isPresented = false
    }
}

// MARK: - Preview

private let previewLogger = Logger(subsystem: "com.TablePro", category: "TableOperationDialog")

#Preview("Drop Table - MySQL") {
    TableOperationDialog(
        isPresented: .constant(true),
        tableName: "users",
        tableCount: 1,
        operationType: .drop,
        databaseType: .mysql
    )        { options in
        previewLogger.debug("Options: \(String(describing: options), privacy: .public)")
    }
}

#Preview("Truncate Table - PostgreSQL") {
    TableOperationDialog(
        isPresented: .constant(true),
        tableName: "orders",
        tableCount: 1,
        operationType: .truncate,
        databaseType: .postgresql
    )        { options in
        previewLogger.debug("Options: \(String(describing: options), privacy: .public)")
    }
}

#Preview("Drop Table - SQLite") {
    TableOperationDialog(
        isPresented: .constant(true),
        tableName: "products",
        tableCount: 1,
        operationType: .drop,
        databaseType: .sqlite
    )        { options in
        previewLogger.debug("Options: \(String(describing: options), privacy: .public)")
    }
}
