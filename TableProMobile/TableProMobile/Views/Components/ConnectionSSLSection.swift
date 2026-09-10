import SwiftUI
import TableProModels

struct ConnectionSSLSection: View {
    @Bindable var viewModel: ConnectionFormViewModel
    var onChooseFile: (CertificateRole) -> Void
    var onChoosePKCS12: () -> Void
    var onPaste: (CertificateRole) -> Void

    var body: some View {
        Section {
            Picker(String(localized: "SSL Mode"), selection: $viewModel.sslMode) {
                Text(String(localized: "Disabled")).tag(SSLConfiguration.SSLMode.disable)
                Text(String(localized: "Required")).tag(SSLConfiguration.SSLMode.require)
                Text(String(localized: "Verify CA")).tag(SSLConfiguration.SSLMode.verifyCa)
                Text(String(localized: "Verify Identity")).tag(SSLConfiguration.SSLMode.verifyFull)
            }

            if viewModel.showsCertificateRows {
                certificateRow(
                    role: .certificateAuthority,
                    title: String(localized: "CA Certificate"),
                    offersPKCS12: false
                )
                certificateRow(
                    role: .clientCertificate,
                    title: String(localized: "Client Certificate"),
                    offersPKCS12: true
                )
                certificateRow(
                    role: .clientKey,
                    title: String(localized: "Client Key"),
                    offersPKCS12: false
                )
            }
        } header: {
            Text("SSL")
        } footer: {
            if viewModel.showsCertificateRows {
                Text("Certificates stay on this device and are never synced. A PKCS#12 file fills in both the client certificate and its key.")
            }
        }
    }

    @ViewBuilder
    private func certificateRow(role: CertificateRole, title: String, offersPKCS12: Bool) -> some View {
        if let summary = viewModel.certificateSummaries[role] {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    viewModel.removeCertificate(role)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Remove"))
            }
        } else {
            Menu {
                Button(String(localized: "Choose File")) { onChooseFile(role) }
                Button(String(localized: "Paste")) { onPaste(role) }
                if offersPKCS12 {
                    Button(String(localized: "Import PKCS#12")) { onChoosePKCS12() }
                }
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Text("Not set")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
