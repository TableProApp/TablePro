import SwiftUI

struct ServiceAccountKeyPasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: ConnectionFormViewModel
    @State private var text = ""
    @State private var problem: String?

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 220)
                } footer: {
                    if let problem {
                        Text(problem)
                            .foregroundStyle(.red)
                    } else {
                        Text("Paste the whole JSON key from Google Cloud, including its braces.")
                    }
                }
            }
            .navigationTitle(String(localized: "Service Account Key"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: text) {
                problem = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: importKey)
                        .disabled(isEmpty)
                }
            }
        }
    }

    private func importKey() {
        if let problem = ConnectionFormViewModel.serviceAccountKeyProblem(text) {
            self.problem = problem
            return
        }
        viewModel.adoptServiceAccountKey(text)
        dismiss()
    }
}
