//
//  CreateDatabaseSheet.swift
//  TablePro
//
//  Sheet for creating a new database with charset and collation options.
//

import SwiftUI

struct CreateDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let databaseType: DatabaseType
    let viewModel: DatabaseSwitcherViewModel

    @State private var databaseName = ""
    @State private var charset: String
    @State private var collation: String
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let config: CreateDatabaseOptions.Config

    init(databaseType: DatabaseType, viewModel: DatabaseSwitcherViewModel) {
        self.databaseType = databaseType
        self.viewModel = viewModel
        let cfg = CreateDatabaseOptions.config(for: databaseType)
        self.config = cfg
        self._charset = State(initialValue: cfg.defaultCharset)
        self._collation = State(initialValue: cfg.defaultCollation)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Create Database")
                .font(.body.weight(.semibold))
                .padding(.vertical, 12)

            Divider()

            // Form
            VStack(alignment: .leading, spacing: 16) {
                // Database name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Database Name")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("Enter database name", text: $databaseName)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                }

                if config.showOptions {
                    // Charset / Encoding
                    VStack(alignment: .leading, spacing: 6) {
                        Text(config.charsetLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $charset) {
                            ForEach(config.charsets, id: \.self) { cs in
                                Text(cs).tag(cs)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.body)
                    }

                    // Collation / LC_COLLATE
                    VStack(alignment: .leading, spacing: 6) {
                        Text(config.collationLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("", selection: $collation) {
                            ForEach(config.collations[charset] ?? [], id: \.self) { col in
                                Text(col).tag(col)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.body)
                    }
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button(isCreating ? String(localized: "Creating...") : String(localized: "Create")) {
                    createDatabase()
                }
                .buttonStyle(.borderedProminent)
                .disabled(databaseName.isEmpty || isCreating)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)
        }
        .frame(width: 380)
        .onExitCommand {
            if !isCreating {
                dismiss()
            }
        }
        .onChange(of: charset) { _, newCharset in
            if let firstCollation = config.collations[newCharset]?.first {
                collation = firstCollation
            }
        }
    }

    private func createDatabase() {
        guard !databaseName.isEmpty else { return }

        isCreating = true
        errorMessage = nil

        let name = databaseName
        let cs = config.showOptions ? charset : ""
        let col: String? = config.showOptions ? collation : nil

        Task {
            do {
                try await viewModel.createDatabase(name: name, charset: cs, collation: col)
                await viewModel.refreshDatabases()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
