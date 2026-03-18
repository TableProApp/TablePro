//
//  CreateDatabaseSheet.swift
//  TablePro
//
//  Sheet for creating a new database with charset and collation options.
//

import SwiftUI

struct CreateDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onCreate: (String, String, String?) async throws -> Void

    @State private var databaseName = ""
    @State private var charset = "utf8mb4"
    @State private var collation = "utf8mb4_unicode_ci"
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let charsets = [
        "utf8mb4",
        "utf8",
        "latin1",
        "ascii"
    ]

    private let collations: [String: [String]] = [
        "utf8mb4": ["utf8mb4_unicode_ci", "utf8mb4_general_ci", "utf8mb4_bin"],
        "utf8": ["utf8_unicode_ci", "utf8_general_ci", "utf8_bin"],
        "latin1": ["latin1_swedish_ci", "latin1_general_ci", "latin1_bin"],
        "ascii": ["ascii_general_ci", "ascii_bin"]
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Create Database")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .semibold))
                .padding(.vertical, 12)

            Divider()

            // Form
            VStack(alignment: .leading, spacing: 16) {
                // Database name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Database Name")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("Enter database name", text: $databaseName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                }

                // Charset
                VStack(alignment: .leading, spacing: 6) {
                    Text("Character Set")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $charset) {
                        ForEach(charsets, id: \.self) { cs in
                            Text(cs).tag(cs)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                }

                // Collation
                VStack(alignment: .leading, spacing: 6) {
                    Text("Collation")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .medium))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $collation) {
                        ForEach(collations[charset] ?? [], id: \.self) { col in
                            Text(col).tag(col)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        .foregroundStyle(.red)
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
            // Prevent dismissing the sheet via ESC while a database is being created
            if !isCreating {
                dismiss()
            }
        }
        .onChange(of: charset) { _, newCharset in
            // Update collation when charset changes
            if let firstCollation = collations[newCharset]?.first {
                collation = firstCollation
            }
        }
    }

    private func createDatabase() {
        guard !databaseName.isEmpty else { return }

        isCreating = true
        errorMessage = nil

        Task {
            do {
                try await onCreate(databaseName, charset, collation)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            }
        }
    }
}
