//
//  DropDatabaseSheet.swift
//  TablePro
//
//  Confirmation dialog for dropping a database.
//

import SwiftUI

struct DropDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let databaseName: String
    let viewModel: DatabaseSwitcherViewModel
    let onDropped: () -> Void

    @State private var isDropping = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Drop Database")
                .font(.body.weight(.semibold))
                .padding(.vertical, 12)

            Divider()

            // Content
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)

                Text(String(format: String(localized: "Drop database '%@'?"), databaseName))
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.center)

                Text(String(localized: "All tables and data will be permanently deleted."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let error = errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isDropping ? String(localized: "Dropping...") : String(localized: "Drop")) {
                    dropDatabase()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDropping)
            }
            .padding(12)
        }
        .frame(width: 340)
        .onExitCommand {
            if !isDropping {
                dismiss()
            }
        }
    }

    private func dropDatabase() {
        isDropping = true
        errorMessage = nil

        Task {
            do {
                try await viewModel.dropDatabase(name: databaseName)
                await viewModel.refreshDatabases()
                onDropped()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDropping = false
            }
        }
    }
}
