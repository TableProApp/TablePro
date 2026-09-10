import SwiftUI

struct CertificatePasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ConnectionFormViewModel
    let role: CertificateRole

    private var title: String {
        switch role {
        case .certificateAuthority: return String(localized: "CA Certificate")
        case .clientCertificate: return String(localized: "Client Certificate")
        case .clientKey: return String(localized: "Client Key")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $viewModel.pastedCertificate)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 220)
                } footer: {
                    Text("Paste the whole PEM block, including its BEGIN and END lines.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.pastedCertificate = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        viewModel.importPastedCertificate(role: role)
                        dismiss()
                    }
                    .disabled(viewModel.pastedCertificate.isEmpty)
                }
            }
        }
    }
}
