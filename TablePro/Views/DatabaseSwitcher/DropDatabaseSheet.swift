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
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Color(nsColor: .systemRed))

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
                    .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(role: .destructive) {
                    dropDatabase()
                } label: {
                    Text(isDropping ? String(localized: "Dropping...") : String(localized: "Drop"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isDropping)
            }
            .padding(12)
        }
        .navigationTitle(String(localized: "Drop Database"))
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
