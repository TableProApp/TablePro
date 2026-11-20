//
//  ProjectNameSheet.swift
//  TablePro
//

import SwiftUI

internal struct ProjectNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?

    // Throwing, because the store refuses an empty name and one another project holds.
    let onCreate: (String) throws -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Project")
                .font(.headline)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("project-name-field")

            if let errorMessage {
                NoticeLabel(errorMessage, severity: .error)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(String(localized: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "Create"), action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("project-name-create")
            }
        }
        .padding(20)
        .frame(width: 300)
        .onChange(of: name) { _ in errorMessage = nil }
        .onExitCommand {
            dismiss()
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func create() {
        do {
            try onCreate(trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
